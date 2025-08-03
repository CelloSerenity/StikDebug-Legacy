//
//  MapSelectionView.swift
//  StikDebug
//
//  Created by Stephen on 8/3/25.
//

import SwiftUI
import MapKit

struct MapSelectionView: UIViewRepresentable {
    @Binding var coordinate: CLLocationCoordinate2D?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapSelectionView

        init(_ parent: MapSelectionView) {
            self.parent = parent
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  let map = gesture.view as? MKMapView
            else { return }

            let point = gesture.location(in: map)
            parent.coordinate = map.convert(point, toCoordinateFrom: map)
        }
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        mapView.addGestureRecognizer(longPress)

        return mapView
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        uiView.removeAnnotations(uiView.annotations)

        if let coord = coordinate {
            let annotation = MKPointAnnotation()
            annotation.coordinate = coord
            uiView.addAnnotation(annotation)

            let region = MKCoordinateRegion(
                center: coord,
                latitudinalMeters: 500,
                longitudinalMeters: 500
            )
            uiView.setRegion(region, animated: true)
        }
    }
}

struct LocationSimulatorView: View {
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var status = ""
    @State private var showKeepOpenError = false
    @State private var searchQuery = ""
    @State private var searchResults: [MKMapItem] = []

    let deviceIp: String

    private var pairingFilePath: String {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist")
            .path
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack{
                Text("")
                HStack() {
                    Text("")
                    Text("")
                    Text("Location Simulator")
                        .font(.largeTitle.bold())
                        .padding(.top)
                    Spacer()
                }
            }
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search for a place", text: $searchQuery, onCommit: performSearch)
                    .font(.body)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
            .padding(12)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
            .padding(.horizontal)

            if !searchResults.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(searchResults, id: \.self) { item in
                            Button(action: { select(item: item) }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name ?? "Unknown")
                                            .font(.body)
                                        Text(item.placemark.title ?? "")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal)
                            }
                            Divider()
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(UIColor.systemBackground)))
                    .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
                    .padding(.horizontal)
                }
                .frame(maxHeight: 200)
            }

            MapSelectionView(coordinate: $coordinate)
                .frame(height: 360)
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                .padding(.horizontal)

            if let coord = coordinate {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Selected Coordinates")
                        .font(.headline)
                    Text(String(format: "%.6f, %.6f", coord.latitude, coord.longitude))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 12)
                                .fill(Color(UIColor.secondarySystemBackground)))
                .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
                .padding(.horizontal)
            } else {
                Text("Long-press on the map or search above to pick a location.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }

            HStack(spacing: 12) {
                Button(action: simulate) {
                    Label("Simulate", systemImage: "location.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordinate == nil)

                Button(action: clear) {
                    Label("Clear", systemImage: "xmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(coordinate == nil)
            }
            .padding(.horizontal)

            if !status.isEmpty {
                Text(status)
                    .font(.callout)
                    .foregroundColor(status.contains("failed") ? .red : .green)
                    .padding(.horizontal)
                    .transition(.opacity)
            }

            Spacer()
        }
        .padding(.bottom)
        .overlay(overlayErrorView)
    }

    private func performSearch() {
        guard !searchQuery.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchQuery
        MKLocalSearch(request: request).start { response, _ in
            searchResults = response?.mapItems ?? []
        }
    }

    private func select(item: MKMapItem) {
        coordinate = item.placemark.coordinate
        status = ""
        searchResults = []
        searchQuery = item.name ?? ""
    }

    private func simulate() {
        guard let coord = coordinate else { return }
        let code = simulate_location(
            deviceIp,
            coord.latitude,
            coord.longitude,
            pairingFilePath
        )
        if code == 0 {
            status = "Simulation running…"
            showKeepOpenError = true
        } else {
            status = "Simulation failed (code \(code))."
        }
    }

    private func clear() {
        let code = clear_simulated_location()
        status = code == 0 ? "Cleared simulation." : "Clear failed (code \(code))."
        showKeepOpenError = false
    }

    @ViewBuilder
    private var overlayErrorView: some View {
        if showKeepOpenError {
            CustomErrorView(
                title: "Keep App Open",
                message: "Your simulation will stop if the app goes to the background. Please keep the app open to continue.",
                onDismiss: { showKeepOpenError = false },
                primaryButtonText: "OK",
                showSecondaryButton: false,
                messageType: .info
            )
            .transition(.opacity.combined(with: .scale))
            .zIndex(1)
        }
    }
}
