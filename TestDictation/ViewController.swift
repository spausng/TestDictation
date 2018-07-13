//
//  ViewController.swift
//  TestDictation
//
//  Created by Sean Paus on 7/12/18.
//  Copyright © 2018 Spaus. All rights reserved.
//

import UIKit
import Starscream
import CoreAudio
import AudioToolbox

class ViewController: UIViewController {
    struct Recorder {
        var recordFile: AudioFileID? = nil
        var recordPacket: Int64 = 0
        var recording: Bool = false
        var socket: WebSocket? = nil
    }
    
    // MARK: - Properties
    var isDictating = false
    var socket: WebSocket?
    var recordFormat = AudioStreamBasicDescription()
    var recorder: Recorder? = nil
    var queue: AudioQueueRef? = nil

    // MARK: - IB Outlets
    @IBOutlet weak var dictationButton: UIButton!
    
    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
}

// MARK: - IB Actions
extension ViewController {
    @IBAction func toggleDictation(_ sender: Any) {
        if (isDictating) {
            // Stop dictation
            stopDictation()
            dictationButton.setTitle("Start Dictation", for: .normal)
            isDictating = false
        } else {
            if (startDictation()) {
                dictationButton.setTitle("Stop Dictation", for: .normal)
                isDictating = true
            }
        }
    }
}

// MARK: - Dictation
extension ViewController {
    func startDictation() -> Bool {
        // 1. Connect socket
        let nvoqDictationURL = URL(string: "wss://eval.nvoq.com:443/wsapi/v2/dictation/topics/general_medicine")
        var nvoqDictationRequest = URLRequest(url: nvoqDictationURL!)
        nvoqDictationRequest.setValue("eval.nvoq.com", forHTTPHeaderField: "Host")
        
        socket = WebSocket(request: nvoqDictationRequest)
        socket?.onConnect = {
            
            // Send STARTDICTATION request
            let startDictation = [
                "apiVersion": "1.0",
                "method": "STARTDICTATION",
                "params": [
                    "id": "spaus@nextgen.com",
                    "apikey": "eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJOZXh0R2VuIChUZW5hbnQpIiwiaXNzIjoiblZvcSIsIm9yZ2hhc2giOiJUbVY0ZEVkbGJsOVVaVzVoYm5SZlh6SXpNRGM2YjNKbllXNXBlbUYwYVc5dU9qTSIsImV4cCI6MTU2Mjc5MjI1NiwiaWF0IjoxNTMxMjU2MjU2fQ.V2PbjLIKV6EQ0uwXn9p1rTbUMSDTnri9cWIivuefbuIfU1ewIE0k8Ix1cjR--dhGqN9NBxGp7QoIUzZfnaepuFCIaPEwWrpPa0GHDGqNJ5lbGeRks7h4-Eh5VvOniZ2unznMZOasYftHavWEJ7y9117Iaq64Ft5Us0NdIxVLRuNiEl1KGUVp_pEVfBAQhSx7GxAFXnbTn6UKxNYnexlfSqo8jHLigkm5QpBxhb9s8Ryhe55ny94a3HiO6TnlspMVhFyUexu49NMEW6cIH4xZ_Jn5oLZMpaYomlwvMxooJ58COFjgbJa1isrTQFcmTSARCcrQIKteZ8BOWR77cb5gfQ",
                    "audioFormat": [
                        "encoding": "pcm-16khz",
                        "sampleRate": 16000
                    ],
                    "snsContext": [
                        "dictationContextText": "",
                        "selectionOffset": 0,
                        "selectionEndIndex": 0
                    ]
                ]
                ] as [String : Any]
            do {
                let startDictationData = try JSONSerialization.data(withJSONObject: startDictation, options: .prettyPrinted)
                if let startDictationJSON = String(data: startDictationData, encoding: .utf8) {
                    self.socket?.write(string: startDictationJSON)
                }
                else {
                    print("Error converting data to JSON string")
                    return
                }
                
            } catch {
                print("caught exception: \(error)")
            }
            
            print("socket connected")
        }
        
        socket?.onDisconnect = { err in
            print("socket disconnected:  err = \(String(describing: err))")
        }
        
        socket?.delegate = self
        socket?.connect()
        
        // 2. Set up recording
        setupAudioFormat() // 16-bit PCM @ 16Kfps
        var error: OSStatus
        recorder = Recorder()
        recorder?.socket = socket
        recorder?.recording = true
        
        let inputCallback: AudioQueueInputCallback = {(inUserData, inQueue, inBuffer, inStartTime, inNumPackets, inPacketDesc) in
            print("in inputCallback")
            guard let inUserData = inUserData else { return }
            var recorder = inUserData.assumingMemoryBound(to: Recorder.self).pointee

            let audioData = Data(bytes: inBuffer.pointee.mAudioData, count: Int(inBuffer.pointee.mAudioDataByteSize))
            print("audioData = \(audioData)")
            recorder.socket?.write(data: audioData)
            
            if inNumPackets > 0 {
                recorder.recordPacket += Int64(inNumPackets)
            }
            
            print("total packets = \(recorder.recordPacket)")
            
            if (recorder.recording) {
                AudioQueueEnqueueBuffer(inQueue, inBuffer, 0, nil)
            }
        }
        
        error = AudioQueueNewInput(&recordFormat, inputCallback, &recorder, nil, nil, 0, &queue)
        
        let numberOfRecordBuffers = 3
        for bufferNumber in 0..<numberOfRecordBuffers {
            var buffer: AudioQueueBufferRef? = nil
            error = AudioQueueAllocateBuffer(queue!, 16000, &buffer)
            
            guard error == noErr else {
                print("error allocating buffer \(bufferNumber)")
                AudioQueueDispose(queue!, true)
                return false
            }
            
            error = AudioQueueEnqueueBuffer(queue!, buffer!, 0, nil)
            guard error == noErr else {
                print("error enqueueing buffer \(bufferNumber)")
                AudioQueueDispose(queue!, true)
                return false
            }
        }
        
        guard error == noErr else {
            print("error creating audio input queue")
            return false
        }
        
        error = AudioQueueStart(queue!, nil)
        guard error == noErr else {
            print("error starting queue")
            return false
        }
        
        return true
    }
    
    func stopDictation() {
        // 1. Stop recording
        var error: OSStatus
        
        AudioQueueFlush(queue!)
        recorder?.recording = false
        error = AudioQueueStop(queue!, true)
        if error != noErr {
            print("AudioQueueStop failed: \(error)")
        }
        AudioQueueDispose(queue!, true)
        
        // 2. Disconnect socket
        // Send AUDIODONE request
        let audioDone = [
            "apiVersion" : "1.0",
            "method": "AUDIODONE"
        ]
        
        do {
            let audioDoneData = try JSONSerialization.data(withJSONObject: audioDone, options: .prettyPrinted)
            if let audioDoneJSON = String(data: audioDoneData, encoding: .utf8) {
                socket?.write(string: audioDoneJSON)
            }
        } catch {
            print("exception encountered: \(error)")
        }
        socket?.disconnect()
        socket = nil
    }
    
    func setupAudioFormat() {
        recordFormat.mSampleRate = 16000.0
        recordFormat.mFormatID = kAudioFormatLinearPCM
        recordFormat.mFramesPerPacket = 1
        recordFormat.mChannelsPerFrame = 1
        recordFormat.mBytesPerFrame = 2
        recordFormat.mBytesPerPacket = 2
        recordFormat.mBitsPerChannel = 16
        recordFormat.mReserved = 0
        recordFormat.mFormatFlags = kLinearPCMFormatFlagIsBigEndian | kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
    }
}

// MARK: - Web Socket Delegate
extension ViewController: WebSocketDelegate {
    func websocketDidConnect(socket: WebSocketClient) {
        print("socket \(socket) did connect")
    }
    
    func websocketDidDisconnect(socket: WebSocketClient, error: Error?) {
        print("socket \(socket) did disconnect: error - \(String(describing: error))")
    }
    
    func websocketDidReceiveMessage(socket: WebSocketClient, text: String) {
        print("socket \(socket) did receive message: \(text)")
    }
    
    func websocketDidReceiveData(socket: WebSocketClient, data: Data) {
        print("socket \(socket) did receive data: \(data)")
    }

}
