//
//  CameraManager.swift
//  Grp 6pm Photo App
//
//  Created by soonqirui on 12/11/26.
//

import Foundation
import AVFoundation
import Observation
@Observable
class CameraManager {
    var session = AVCaptureSession()
    func configure(){
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for:.video, position:.back) else{
            print("Sorry the camera got munched")
            return
            
        }
        session.beginConfiguration()
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) {
                session.addInput(input)
            }
        } catch {
            print("Something went wrong: \(error)")
        }
        session.commitConfiguration()
    }
    func start() async {
        let granted = await AVCaptureDevice.requestAccess(for:.video)
        guard granted else {
            print("sorry ur device does not like us")
            return
        }
       
        configure()
        session.startRunning()
    }
}
