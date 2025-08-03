//
//  MainTabView.swift
//  StikJIT
//
//  Created by Stephen on 3/27/25.
//

import SwiftUI
import UIKit

fileprivate struct TabItem: Identifiable, Hashable {
    let id: Int
    let title: String
    let systemImage: String
}

fileprivate struct BlurView: UIViewRepresentable {
    let style: UIBlurEffect.Style
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}

fileprivate struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners
    func path(in rect: CGRect) -> Path {
        Path(
            UIBezierPath(
                roundedRect: rect,
                byRoundingCorners: corners,
                cornerRadii: CGSize(width: radius, height: radius)
            ).cgPath
        )
    }
}
fileprivate extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

fileprivate struct CustomTabBar: View {
    let items: [TabItem]
    @Binding var selection: Int
    let accentColor: Color

    var body: some View {
        HStack {
            ForEach(items) { item in
                Spacer()
                Button(action: { withAnimation { selection = item.id } }) {
                    VStack(spacing: 4) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 20, weight: .semibold))
                        Text(item.title)
                            .font(.caption)
                    }
                    .foregroundColor(selection == item.id ? accentColor : .secondary)
                }
                Spacer()
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            BlurView(style: .systemMaterial)
                .ignoresSafeArea(edges: .bottom)
        )
        .cornerRadius(16, corners: .allCorners)
        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: -2)
    }
}

struct MainTabView: View {
    @AppStorage("customAccentColor") private var customAccentColorHex: String = ""
    @AppStorage("enableAdvancedOptions") private var enableAdvancedOptions = false
    @AppStorage("enableTesting") private var enableTesting = false

    @State private var selection: Int = 0
    @State private var isTabBarHidden: Bool = false

    private var accentColor: Color {
        customAccentColorHex.isEmpty
            ? .blue
            : Color(hex: customAccentColorHex) ?? .blue
    }

    private var locationTabId: Int? {
        #if DEBUG
        return 3
        #else
        return nil
        #endif
    }

    private var tabs: [TabItem] {
        var items: [TabItem] = [
            TabItem(id: 0, title: "Home",    systemImage: "house"),
            TabItem(id: 1, title: "Scripts", systemImage: "scroll"),
            TabItem(id: 2, title: "Testing", systemImage: "square.grid.2x2"),
        ]
        #if DEBUG
        items += [
            TabItem(id: 3, title: "Location", systemImage: "globe.americas"),
            TabItem(id: 4, title: "Info",     systemImage: "info.circle.fill"),
            TabItem(id: 5, title: "Settings", systemImage: "gearshape.fill")
        ]
        #else
        items += [
            TabItem(id: 3, title: "Info",     systemImage: "info.circle.fill"),
            TabItem(id: 4, title: "Settings", systemImage: "gearshape.fill")
        ]
        #endif
        return items
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch selection {
                case 0: HomeView()
                case 1: ScriptListView()
                case 2: IPAAppManagerView()
                #if DEBUG
                case 3: LocationSimulatorView(deviceIp: "10.7.0.2")
                case 4: DeviceInfoView()
                case 5: SettingsView()
                #else
                case 3: DeviceInfoView()
                case 4: SettingsView()
                #endif
                default: HomeView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accentColor(accentColor)
            .environment(\.accentColor, accentColor)

            CustomTabBar(items: tabs,
                         selection: $selection,
                         accentColor: accentColor)
                .offset(
                    x: isTabBarHidden ? -UIScreen.main.bounds.width : 0,
                    y: -40
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.7),
                           value: isTabBarHidden)
        }
        .onChange(of: selection) { new in
            if let loc = locationTabId, new == loc {
                withAnimation {
                    isTabBarHidden = false
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 30, coordinateSpace: .global)
                .onEnded { value in
                    guard selection != locationTabId else { return }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        if value.translation.width < -30 {
                            isTabBarHidden = true
                        } else if value.translation.width > 30 {
                            isTabBarHidden = false
                        }
                    }
                }
        )
        .edgesIgnoringSafeArea(.bottom)
    }
}
