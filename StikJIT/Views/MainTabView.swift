//
//  MainTabView.swift
//  StikJIT
//
//  Created by Stephen on 3/27/25.
//

import SwiftUI
import UIKit

struct TabItem: Identifiable, Hashable {
    let id: Int
    let title: String
    let systemImage: String
}

struct BlurView: UIViewRepresentable {
    let style: UIBlurEffect.Style
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners
    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

@inline(__always)
fileprivate func smoothstep(_ x: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
    if a == b { return x >= b ? 1 : 0 }
    let t = max(0, min(1, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}

fileprivate let drawerSpring: Animation = .interactiveSpring(response: 0.42, dampingFraction: 0.86, blendDuration: 0.1)

fileprivate struct DrawerHandle: View {
    let progress: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: 2.5)
            .frame(width: 40, height: 5)
            .foregroundColor(.secondary)
            .padding(.top, 8)
            .scaleEffect(1 + 0.10 * progress)
            .opacity(0.9 + 0.1 * (1 - progress))
            .animation(drawerSpring, value: progress)
    }
}

fileprivate struct FavoritesDockView: View {
    let favorites: [TabItem]
    @Binding var selection: Int
    let accentColor: Color
    let progress: CGFloat
    let bottomPadding: CGFloat

    var body: some View {
        let fade = 1 - smoothstep(progress, 0.30, 0.55)
        let yLift: CGFloat = 8 * smoothstep(progress, 0.00, 0.55)
        HStack {
            Spacer()
            ForEach(favorites.indices, id: \.self) { i in
                let item = favorites[i]
                Button {
                    selection = item.id
                } label: {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(selection == item.id ? accentColor : .secondary)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(Text(item.title))
                }
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.bottom, bottomPadding)
        .opacity(fade)
        .offset(y: yLift)
        .animation(drawerSpring, value: progress)
        .allowsHitTesting(progress < 0.5)
        .zIndex(progress < 0.5 ? 1 : 0)
    }
}

fileprivate struct AppGridView: View {
    static let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 16), count: 4)
    let items: [TabItem]
    @Binding var selection: Int
    let accentColor: Color
    let progress: CGFloat
    let slotMap: [Int: Int]
    let assignToSlot: (Int, Int) -> Void
    let debugLocationId: Int?

    var body: some View {
        let fade = smoothstep(progress, 0.45, 0.75)
        let yRise: CGFloat = 14 * (1 - fade)

        ScrollView {
            LazyVGrid(columns: Self.columns, spacing: 16) {
                ForEach(items.indices, id: \.self) { i in
                    let item = items[i]
                    Button {
                        selection = item.id
                    } label: {
                        VStack(spacing: 8) {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: item.systemImage)
                                    .font(.system(size: 24, weight: .semibold))
                                    .frame(maxWidth: .infinity, alignment: .center)
                                if let slot = slotMap[item.id] {
                                    Text("\(slot)")
                                        .font(.system(size: 10, weight: .bold))
                                        .padding(4)
                                        .background(.ultraThinMaterial, in: Capsule())
                                        .offset(x: 6, y: -6)
                                        .accessibilityLabel(Text("Favorites Dock position \(slot)"))
                                }
                            }
                            Text(item.title)
                                .font(.caption)
                        }
                        .foregroundColor(selection == item.id ? accentColor : .primary)
                        .padding(8)
                    }
                    .contextMenu {
                        Text("Add to Favorites Dock")
                        Divider()
                        ForEach(1...4, id: \.self) { position in
                            Button {
                                assignToSlot(item.id, position)
                            } label: {
                                if slotMap[item.id] == position {
                                    Label("Position \(position) • Assigned", systemImage: "checkmark.circle.fill")
                                } else {
                                    Text("Position \(position)")
                                }
                            }
                        }
                        #if DEBUG
                        if let locId = debugLocationId, item.id == locId {
                            Divider()
                            Text("Location Options")
                            Button("Open Location Simulator") {
                                selection = locId
                            }
                        }
                        #endif
                    }
                    .scaleEffect(0.98 + 0.02 * fade)
                }
            }
            .padding()
        }
        .scrollDisabled(true)
        .scrollIndicators(.hidden)
        .opacity(fade)
        .offset(y: yRise)
        .animation(drawerSpring, value: progress)
        .allowsHitTesting(progress > 0.6)
        .zIndex(progress >= 0.5 ? 1 : 0)
    }
}

struct AppDrawer: View {
    let items: [TabItem]
    @Binding var selection: Int
    let accentColor: Color
    @AppStorage("favoritesDockPosition1") private var favPos1: Int = 0
    @AppStorage("favoritesDockPosition2") private var favPos2: Int = 2
    @AppStorage("favoritesDockPosition3") private var favPos3: Int = 3
    @AppStorage("favoritesDockPosition4") private var favPos4: Int = 4
    @State private var progress: CGFloat = 0
    @State private var dragStartProgress: CGFloat = 0
    @State private var isDragging = false
    private var maxHeight: CGFloat { UIScreen.main.bounds.height * 0.5 }
    private var minHeight: CGFloat { 80 }

    private var favorites: [TabItem] {
        let ids = [favPos1, favPos2, favPos3, favPos4]
        let found: [TabItem] = ids.compactMap { id in items.first(where: { $0.id == id }) }
        if found.count == 4 { return found }
        let defaults = [0, 2, 3, 4].compactMap { id in items.first(where: { $0.id == id }) }
        return defaults
    }

    private var slotMap: [Int: Int] {
        var dict: [Int: Int] = [:]
        dict[favPos1] = 1
        dict[favPos2] = 2
        dict[favPos3] = 3
        dict[favPos4] = 4
        return dict
    }

    private func assign(_ itemId: Int, to position: Int) {
        let defaults = [0, 2, 3, 4]
        switch position {
        case 1:
            if favPos2 == itemId { favPos2 = defaults[1] }
            if favPos3 == itemId { favPos3 = defaults[2] }
            if favPos4 == itemId { favPos4 = defaults[3] }
            favPos1 = itemId
        case 2:
            if favPos1 == itemId { favPos1 = defaults[0] }
            if favPos3 == itemId { favPos3 = defaults[2] }
            if favPos4 == itemId { favPos4 = defaults[3] }
            favPos2 = itemId
        case 3:
            if favPos1 == itemId { favPos1 = defaults[0] }
            if favPos2 == itemId { favPos2 = defaults[1] }
            if favPos4 == itemId { favPos4 = defaults[3] }
            favPos3 = itemId
        case 4:
            if favPos1 == itemId { favPos1 = defaults[0] }
            if favPos2 == itemId { favPos2 = defaults[1] }
            if favPos3 == itemId { favPos3 = defaults[2] }
            favPos4 = itemId
        default: break
        }
    }

    var body: some View {
        GeometryReader { geo in
            let safeBottom = geo.safeAreaInsets.bottom
            let totalHeight = maxHeight + safeBottom
            let dockClearance: CGFloat = safeBottom + 16
            let closedY = geo.size.height - minHeight - safeBottom - dockClearance
            let openY   = geo.size.height - totalHeight
            let travel  = closedY - openY
            let offsetY = closedY - progress * travel
            let dockBottomPadding = safeBottom + 8

            ZStack {
                if progress > 0 {
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { withAnimation(drawerSpring) { progress = 0 } }
                }
                VStack(spacing: 0) {
                    DrawerHandle(progress: progress)
                        .onTapGesture {
                            withAnimation(drawerSpring) {
                                progress = (progress >= 0.999) ? 0 : 1
                            }
                        }
                    ZStack(alignment: .top) {
                        FavoritesDockView(favorites: favorites,
                                          selection: $selection,
                                          accentColor: accentColor,
                                          progress: progress,
                                          bottomPadding: dockBottomPadding)
                            .padding(.top, 10)
                        AppGridView(items: items,
                                    selection: $selection,
                                    accentColor: accentColor,
                                    progress: progress,
                                    slotMap: slotMap,
                                    assignToSlot: { itemId, pos in assign(itemId, to: pos) },
                                    debugLocationId: items.first(where: { $0.title == "Location" })?.id)
                            .padding(.top, 10)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(width: geo.size.width, height: totalHeight, alignment: .top)
                .background(
                    BlurView(style: .systemMaterial)
                        .cornerRadius(16 + 8 * progress, corners: [.topLeft, .topRight])
                        .shadow(color: Color.black.opacity(0.15 * Double(progress)), radius: 14 * progress, x: 0, y: -4 * progress)
                        .ignoresSafeArea(edges: .bottom)
                )
                .offset(y: offsetY)
                .animation(drawerSpring, value: progress)
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            if !isDragging {
                                isDragging = true
                                dragStartProgress = progress
                            }
                            let delta = v.translation.height
                            let p = dragStartProgress - delta / travel
                            progress = min(max(p, 0), 1)
                        }
                        .onEnded { v in
                            isDragging = false
                            let end = dragStartProgress - v.translation.height / travel
                            let target: CGFloat = end > 0.5 ? 1 : 0
                            withAnimation(drawerSpring) { progress = target }
                        }
                )
            }
        }
    }
}

struct MainTabView: View {
    @AppStorage("customAccentColor") private var customAccentColorHex: String = ""
    @State private var selection: Int = 0

    private var accentColor: Color {
        customAccentColorHex.isEmpty ? .blue : (Color(hex: customAccentColorHex) ?? .blue)
    }

    private var tabs: [TabItem] {
        var base: [TabItem] = [
            TabItem(id: 0, title: "Home",     systemImage: "house"),
            TabItem(id: 1, title: "Scripts",  systemImage: "scroll"),
            TabItem(id: 2, title: "Testing",  systemImage: "square.grid.2x2"),
            TabItem(id: 3, title: "Info",     systemImage: "info.circle.fill"),
            TabItem(id: 4, title: "Settings", systemImage: "gearshape.fill")
        ]
        #if DEBUG
        base.append(TabItem(id: 5, title: "Location", systemImage: "globe.americas"))
        #endif
        return base
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch selection {
                case 0: HomeView()
                case 1: ScriptListView()
                case 2: IPAAppManagerView()
                #if DEBUG
                case 5: LocationSimulatorView(deviceIp: "10.7.0.2")
                #endif
                case 3: DeviceInfoView()
                case 4: SettingsView()
                default: HomeView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accentColor(accentColor)
            .environment(\.accentColor, accentColor)
            AppDrawer(items: tabs, selection: $selection, accentColor: accentColor)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

struct MainTabView_Preview: PreviewProvider {
    static var previews: some View {
        MainTabView()
    }
}
