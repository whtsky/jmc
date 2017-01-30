//
//  PeerBrowser.swift
//  minimalTunes
//
//  Created by John Moody on 12/15/16.
//  Copyright © 2016 John Moody. All rights reserved.
//

import Cocoa
import MultipeerConnectivity

class ConnectivityManager: NSObject, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate, MCSessionDelegate {
    
    let serviceIdentifier = "j-tunes"
    let thisPeerID = MCPeerID(displayName: NSHost.currentHost().localizedName!)
    let serviceAdvertiser: MCNearbyServiceAdvertiser
    let serviceBrowser: MCNearbyServiceBrowser
    let interface: SourceListViewController?
    let metadataDelegate: SharedLibraryRequestHandler?
    let databaseManager: DatabaseManager
    var requestedTrackDatas = [Int : Track]()
    
    var delegate: AppDelegate?
    
    lazy var session : MCSession = {
        let session = MCSession(peer: self.thisPeerID, securityIdentity: nil, encryptionPreference: MCEncryptionPreference.None)
        session.delegate = self
        return session
    }()
    
    init(delegate: AppDelegate, slvc: SourceListViewController) {
        self.interface = slvc
        self.delegate = delegate
        self.databaseManager = DatabaseManager()
        self.metadataDelegate = SharedLibraryRequestHandler()
        self.serviceAdvertiser = MCNearbyServiceAdvertiser(peer: thisPeerID, discoveryInfo: nil, serviceType: serviceIdentifier)
        self.serviceBrowser = MCNearbyServiceBrowser(peer: thisPeerID, serviceType: serviceIdentifier)
        super.init()
        self.serviceAdvertiser.delegate = self
        self.serviceAdvertiser.startAdvertisingPeer()
        self.serviceBrowser.delegate = self
        self.serviceBrowser.startBrowsingForPeers()
        slvc.server = self
    }
    
    deinit {
        self.serviceAdvertiser.stopAdvertisingPeer()
        self.serviceBrowser.stopBrowsingForPeers()
    }
    
    //mark advertiser
    func advertiser(advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: NSError) {
        print(error)
    }
    
    func advertiser(advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: NSData?, invitationHandler: (Bool, MCSession) -> Void) {
        print("got invitation from \(peerID)")
        invitationHandler(true, self.session)
    }
    
    //mark browser
    func browser(browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        print("lost peer: \(peerID)")
        //interface!.removeNetworkedLibrary(peerID)
    }
    
    func browser(browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: NSError) {
        print("error starting browsering: \(error)")
    }
    
    func browser(browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        print("found peer: \(peerID) with info \(info)")
        browser.invitePeer(peerID, toSession: self.session, withContext: nil, timeout: 10)
    }
    
    //mark session
    func session(session: MCSession, didReceiveData data: NSData, fromPeer peerID: MCPeerID) {
        print("received data from peer \(peerID)")
        var requestDict: NSDictionary!
        do {
            requestDict = try NSJSONSerialization.JSONObjectWithData(data, options: NSJSONReadingOptions.AllowFragments) as! NSDictionary
        } catch {
            print(error)
        }
        let dataType = requestDict["type"] as! String
        switch dataType {
        case "request":
            print("data was a request")
            parseRequest(peerID, requestDict: requestDict)
        case "payload":
            parsePayload(peerID, requestDict: requestDict)
        default:
            print("the tingler detects an invalid transfer")
        }
    }
    func session(session: MCSession, peer peerID: MCPeerID, didChangeState state: MCSessionState) {
        print("peer \(peerID) session \(session) changed state to \(state.rawValue)")
        if state == MCSessionState.Connected {
            sendPeerLibraryName(peerID)
        } else if state == MCSessionState.NotConnected {
            dispatch_async(dispatch_get_main_queue()) {
                self.interface?.removeNetworkedLibrary(peerID)
            }
            serviceBrowser.invitePeer(peerID, toSession: self.session, withContext: nil, timeout: 10)
        }
    }
    func session(session: MCSession, didReceiveStream stream: NSInputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        print("got \(stream) with name \(streamName) from peer \(peerID)")
    }
    func session(session: MCSession, didReceiveCertificate certificate: [AnyObject]?, fromPeer peerID: MCPeerID, certificateHandler: (Bool) -> Void) {
        print("got a certificate \(certificate) from \(peerID)")
        certificateHandler(true)
    }
    func session(session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, withProgress progress: NSProgress) {
        print("started getting resource \(resourceName) from peer \(peerID) with progress \(progress)")
    }
    func session(session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, atURL localURL: NSURL, withError error: NSError?) {
        print("finished getting resource \(resourceName) from peer \(peerID) at url \(localURL) with error \(error)")
    }
    
    func getTrack(id: Int, peer: MCPeerID) {
        askPeerForSong(peer, id: id)
    }
    
    func getDataForPlaylist(item: SourceListNode) {
        print("about to ask peer for playlist")
        let peer = item.item.library!.peer as! MCPeerID
        let visibleColumns = NSUserDefaults.standardUserDefaults().objectForKey(DEFAULTS_SAVED_COLUMNS_STRING) as! NSDictionary
        let visibleColumnsArray = visibleColumns.allKeysForObject(false) as! [String]
        let id = item.item.playlist!.id! as Int
        askPeerForPlaylist(peer, id: id, visibleColumns: visibleColumnsArray)
    }
    
    func parsePayload(peer: MCPeerID, requestDict: NSDictionary) {
        let payloadType = requestDict["payload"] as! String
        switch payloadType {
        case "name":
            dispatch_async(dispatch_get_main_queue()) {
                self.interface!.addNetworkedLibrary(peer)
            }
            self.askPeerForSourceList(peer)
        case "list":
            let list = requestDict["list"] as! [NSDictionary]
            dispatch_async(dispatch_get_main_queue()) {
                self.interface!.addSourcesForNetworkedLibrary(list, peer: peer)
            }
        case "playlist":
            let requestedID = requestDict["id"] as! Int
            let item = interface!.getNetworkPlaylist(requestedID)
            let playlist = requestDict["playlist"] as? NSDictionary
            dispatch_async(dispatch_get_main_queue()) {
                if playlist != nil {
                    self.databaseManager.addTracksForPlaylistData(playlist!, item: item!)
                    self.interface!.doneAddingNetworkPlaylistCallback(item!)
                }
            }
            print("the tingler got a playlist")
        case "track":
            guard delegate!.mainWindowController?.is_streaming == true else {return}
            let trackB64 = requestDict["track"] as! String
            let trackData = NSData(base64EncodedString: trackB64, options: NSDataBase64DecodingOptions.IgnoreUnknownCharacters)
            guard trackData != nil else {return}
            databaseManager.saveStreamingNetworkTrack(delegate!.mainWindowController!.currentTrack!, data: trackData!)
            dispatch_async(dispatch_get_main_queue()) {
                self.delegate!.mainWindowController!.playNetworkSongCallback()
            }
            print("the tingler got a song")
        case "track download":
            guard let track = (self.requestedTrackDatas[requestDict["id"] as! Int]) else {return}
            self.requestedTrackDatas.removeValueForKey(requestDict["id"] as! Int)
            let trackB64 = requestDict["track"] as! String
            guard let trackData = NSData(base64EncodedString: trackB64, options: NSDataBase64DecodingOptions.IgnoreUnknownCharacters) else {return}
            guard let trackMetadata = requestDict["metadata"] as? NSDictionary else {return}
            let databaseManager = DatabaseManager()
            dispatch_async(dispatch_get_main_queue()) {
                databaseManager.createFileForNetworkTrack(track, data: trackData, trackMetadata: trackMetadata)
            }
            print("the tingler got a song download")
        default:
            print("the tingler got an invalid payload")
        }
    }
    
    func parseRequest(peer: MCPeerID, requestDict: NSDictionary) {
        guard (requestDict["type"] as! String) == "request" else {return}
        let request = requestDict["request"] as! String
        switch request {
        case "name":
            sendPeerLibraryName(peer)
        case "list":
            sendPeerSourceList(peer)
        case "playlist":
            print("got request for playlist")
            let playlistID = requestDict["id"] as! Int
            let visibleColumnsArray = requestDict["fields"] as! [String]
            sendPeerPlaylistInfo(peer, playlistID: playlistID, visibleColumns: visibleColumnsArray)
        case "track":
            let id = requestDict["id"] as! Int
            sendPeerTrack(peer, trackID: id)
        case "track download":
            let id = requestDict["id"] as! Int
            sendPeerTrackDownload(peer, trackID: id)
        default:
            print("the tingler detects an invalid request")
        }
    }
    
    func sendPeerPlaylistInfo(peer: MCPeerID, playlistID: Int, visibleColumns: [String]) {
        let playlist = metadataDelegate!.getPlaylist(playlistID, fields: visibleColumns)
        let playlistPayloadDictionary = NSMutableDictionary()
        playlistPayloadDictionary["type"] = "payload"
        playlistPayloadDictionary["payload"] = "playlist"
        playlistPayloadDictionary["library"] = NSUserDefaults.standardUserDefaults().stringForKey(DEFAULTS_LIBRARY_NAME_STRING)
        playlistPayloadDictionary["id"] = playlistID
        playlistPayloadDictionary["playlist"] = playlist
        var serializedDict: NSData!
        do {
            serializedDict = try NSJSONSerialization.dataWithJSONObject(playlistPayloadDictionary, options: NSJSONWritingOptions.PrettyPrinted)
            try self.session.sendData(serializedDict, toPeers: [peer], withMode: .Reliable)
        } catch {
            print(error)
        }
    }
    
    func sendPeerTrack(peer: MCPeerID, trackID: Int) {
        let trackData = metadataDelegate!.getSong(trackID)
        let trackPayloadDictionary = NSMutableDictionary()
        trackPayloadDictionary["type"] = "payload"
        trackPayloadDictionary["payload"] = "track"
        trackPayloadDictionary["track"] = trackData?.base64EncodedStringWithOptions(NSDataBase64EncodingOptions.Encoding64CharacterLineLength)
        var serializedDict: NSData!
        do {
            serializedDict = try NSJSONSerialization.dataWithJSONObject(trackPayloadDictionary, options: NSJSONWritingOptions.PrettyPrinted)
            try session.sendData(serializedDict, toPeers: [peer], withMode: .Reliable)
        } catch {
            print(error)
        }
    }
    
    func sendPeerTrackDownload(peer: MCPeerID, trackID: Int) {
        let trackData = metadataDelegate!.getSong(trackID)
        let trackPayloadDictionary = NSMutableDictionary()
        trackPayloadDictionary["type"] = "payload"
        trackPayloadDictionary["payload"] = "track download"
        trackPayloadDictionary["id"] = trackID
        trackPayloadDictionary["track"] = trackData?.base64EncodedStringWithOptions(NSDataBase64EncodingOptions.Encoding64CharacterLineLength)
        trackPayloadDictionary["metadata"] = metadataDelegate!.getAllMetadataForTrack(trackID)
        var serializedDict: NSData!
        do {
            serializedDict = try NSJSONSerialization.dataWithJSONObject(trackPayloadDictionary, options: NSJSONWritingOptions.PrettyPrinted)
            print("sending song")
            try session.sendData(serializedDict, toPeers: [peer], withMode: .Reliable)
        } catch {
            print(error)
        }
    }
    
    func sendPeerLibraryName(peer: MCPeerID) {
        let libraryName = NSUserDefaults.standardUserDefaults().stringForKey(DEFAULTS_LIBRARY_NAME_STRING)
        let libraryNameDictionary = NSMutableDictionary()
        libraryNameDictionary["type"] = "payload"
        libraryNameDictionary["payload"] = "name"
        libraryNameDictionary["name"] = libraryName
        var serializedDict: NSData!
        do {
            serializedDict = try NSJSONSerialization.dataWithJSONObject(libraryNameDictionary, options: NSJSONWritingOptions.PrettyPrinted)
            try session.sendData(serializedDict, toPeers: [peer], withMode: .Reliable)
        } catch {
            print(error)
        }
    }
    
    func sendPeerSourceList(peer: MCPeerID) {
        let sourceList = metadataDelegate!.getSourceList()
        let sourceListPayloadDictionary = NSMutableDictionary()
        sourceListPayloadDictionary["name"] = NSUserDefaults.standardUserDefaults().stringForKey("libraryName")
        sourceListPayloadDictionary["type"] = "payload"
        sourceListPayloadDictionary["payload"] = "list"
        sourceListPayloadDictionary["list"] = sourceList
        var serializedDict: NSData!
        do {
            serializedDict = try NSJSONSerialization.dataWithJSONObject(sourceListPayloadDictionary, options: NSJSONWritingOptions.PrettyPrinted)
            try session.sendData(serializedDict, toPeers: [peer], withMode: .Reliable)
        } catch {
            print(error)
        }
    }
    
    func askPeerForLibraryName(peer: MCPeerID) {
        let requestDictionary = NSMutableDictionary()
        requestDictionary["type"] = "request"
        requestDictionary["request"] = "name"
        var data: NSData!
        do {
            data = try NSJSONSerialization.dataWithJSONObject(requestDictionary, options: NSJSONWritingOptions.PrettyPrinted)
            try session.sendData(data, toPeers: [peer], withMode: .Reliable)
        } catch {
            print("error asking for library name: \(error)")
        }
    }
    
    func askPeerForSourceList(peer: MCPeerID) {
        let requestDictionary = NSMutableDictionary()
        requestDictionary["type"] = "request"
        requestDictionary["request"] = "list"
        var data: NSData!
        do {
            data = try NSJSONSerialization.dataWithJSONObject(requestDictionary, options: NSJSONWritingOptions.PrettyPrinted)
            try session.sendData(data, toPeers: [peer], withMode: .Reliable)
        } catch {
            print("error asking for source list: \(error)")
        }
    }
    
    func askPeerForPlaylist(peer: MCPeerID, id: Int, visibleColumns: [String]) {
        let requestDictionary = NSMutableDictionary()
        requestDictionary["type"] = "request"
        requestDictionary["request"] = "playlist"
        requestDictionary["fields"] = visibleColumns
        requestDictionary["id"] = id
        var data: NSData!
        do {
            data = try NSJSONSerialization.dataWithJSONObject(requestDictionary, options: NSJSONWritingOptions.PrettyPrinted)
            print("sending playlist request to peer")
            try session.sendData(data, toPeers: [peer], withMode: .Reliable)
        } catch {
            print("error asking for playlist: \(error)")
        }
    }
    
    func askPeerForSong(peer: MCPeerID, id: Int) {
        let requestDictionary = NSMutableDictionary()
        requestDictionary["type"] = "request"
        requestDictionary["request"] = "track"
        requestDictionary["id"] = id
        var data: NSData!
        do {
            data = try NSJSONSerialization.dataWithJSONObject(requestDictionary, options: NSJSONWritingOptions.PrettyPrinted)
            try session.sendData(data, toPeers: [peer], withMode: MCSessionSendDataMode.Reliable)
        } catch {
            print("error asking for song: \(error)")
        }
    }
    
    func askPeerForSongDownload(peer: MCPeerID, track: Track) {
        let requestDictionary = NSMutableDictionary()
        requestDictionary["type"] = "request"
        requestDictionary["request"] = "track download"
        requestDictionary["id"] = track.id!
        self.requestedTrackDatas[Int(track.id!)] = track
        var data: NSData!
        do {
            data = try NSJSONSerialization.dataWithJSONObject(requestDictionary, options: NSJSONWritingOptions.PrettyPrinted)
            try session.sendData(data, toPeers: [peer], withMode: MCSessionSendDataMode.Reliable)
        } catch {
            print("error asking for song download: \(error)")
        }
        
    }
}