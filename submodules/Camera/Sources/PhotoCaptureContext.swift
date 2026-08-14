import Foundation
import AVFoundation
import UIKit
import SwiftSignalKit
import CoreImage

public enum PhotoCaptureResult: Equatable {
    case began
    case finished(UIImage, UIImage?, Double)
    case failed
    
    public static func == (lhs: PhotoCaptureResult, rhs: PhotoCaptureResult) -> Bool {
        switch lhs {
        case .began:
            if case .began = rhs {
                return true
            } else {
                return false
            }
        case .failed:
            if case .failed = rhs {
                return true
            } else {
                return false
            }
        case let .finished(_, _, lhsTime):
            if case let .finished(_, _, rhsTime) = rhs, lhsTime == rhsTime {
                return true
            } else {
                return false
            }
        }
    }
}

final class PhotoCaptureContext: NSObject, AVCapturePhotoCaptureDelegate {
    private let ciContext: CIContext
    private let pipe = ValuePipe<PhotoCaptureResult>()
    private let orientation: AVCaptureVideoOrientation
    private let mirror: Bool
    
    /// Long-edge cap for the UIImage handed to the editor. A 12 MP capture is
    /// enough to jetsam on mid-range devices; 2560 covers 1080×1920 stories
    /// with crop headroom without keeping the full sensor buffer.
    private let maxLongEdge: CGFloat = 2560.0
    
    init(ciContext: CIContext, settings: AVCapturePhotoSettings, orientation: AVCaptureVideoOrientation, mirror: Bool) {
        self.ciContext = ciContext
        self.orientation = orientation
        self.mirror = mirror
        
        super.init()
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        self.pipe.putNext(.began)
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let _ = error {
            self.pipe.putNext(.failed)
        } else {
            guard let photoPixelBuffer = photo.pixelBuffer else {
                print("Error occurred while capturing photo: Missing pixel buffer (\(String(describing: error)))")
                self.pipe.putNext(.failed)
                return
            }
            
            let orientation = exifOrientation(for: self.orientation, mirror: self.mirror)
            var ci = CIImage(cvImageBuffer: photoPixelBuffer).oriented(forExifOrientation: orientation)
            let extent = ci.extent
            let longest = max(extent.width, extent.height)
            if longest > self.maxLongEdge, longest > .ulpOfOne {
                let scale = self.maxLongEdge / longest
                ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
            if let cgImage = self.ciContext.createCGImage(ci, from: ci.extent) {
                let image = UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
                self.pipe.putNext(.finished(image, nil, CACurrentMediaTime()))
            } else {
                self.pipe.putNext(.failed)
            }
        }
    }
    
    var signal: Signal<PhotoCaptureResult, NoError> {
        return self.pipe.signal()
        |> take(until: { next in
            let complete: Bool
            switch next {
            case .finished, .failed:
                complete = true
            default:
                complete = false
            }
            return SignalTakeAction(passthrough: true, complete: complete)
        })
    }
}
