//
//  SharedStubs.swift
//  StikJIT
//
//  Created by Stephen on 09/12/2025.
//

import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - Shared glass card wrapper (renamed to avoid conflicts)

@ViewBuilder
func appGlassCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    MaterialCard {
        content()
    }
}

// MARK: - Open App Folder helper

func openAppFolder() {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let controller = UIActivityViewController(activityItems: [docs], applicationActivities: nil)
    controller.excludedActivityTypes = [.assignToContact, .saveToCameraRoll, .postToFacebook, .postToTwitter]
    DispatchQueue.main.async {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        root.present(controller, animated: true)
    }
}
