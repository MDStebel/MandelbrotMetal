//
//  PhotoSaver.swift
//  Mandelbrot Metal
//
//  Created by Michael Stebel on 8/13/25.
//

import MetalKit
import PhotosUI
import Photos
import SwiftUI
import UIKit
import simd


enum PhotoSaveError: Error {
    case notAuthorized
    case writeFailed(Error?)
}

final class PhotoSaver {
    static let shared = PhotoSaver()
    
    /// Requests add-only permission if needed, then saves the image to Photos.
    func saveToPhotos(_ image: UIImage, completion: @escaping (Result<Void, PhotoSaveError>) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(.failure(.notAuthorized)) }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }, completionHandler: { ok, err in
                DispatchQueue.main.async {
                    ok ? completion(.success(())) : completion(.failure(.writeFailed(err)))
                }
            })
        }
    }
}
