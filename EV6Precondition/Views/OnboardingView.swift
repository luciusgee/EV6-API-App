import PreconditionKit
import SwiftUI

/// First launch: what the app does, what you need, your car, and the safety note.
struct OnboardingView: View {
    @Environment(OBDService.self) private var obd
    @Bindable var prefs: Preferences
    @State private var page = 0
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 60

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcome.tag(0)
                adapter.tag(1)
                car.tag(2)
                safety.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .animation(.easeInOut, value: page)
        }
        .background(
            LinearGradient(colors: [Color(red: 0.12, green: 0.14, blue: 0.2), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .interactiveDismissDisabled()
    }

    private func next(_ title: String = "Continue") -> some View {
        Button {
            page += 1
        } label: {
            Text(title).font(.headline).frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 50)
        .background(.black)
    }

    /// Scrolls when the content is taller than the page (large Dynamic Type, small phones),
    /// and stays vertically centred when it fits.
    private func pageLayout<Content: View>(icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        let content = content()
        return GeometryReader { geo in
            ScrollView {
                VStack(spacing: 22) {
                    Spacer(minLength: 20)
                    Image(systemName: icon)
                        .font(.system(size: iconSize, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text(title)
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                    content
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 28)
                    Spacer(minLength: 20)
                }
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var welcome: some View {
        pageLayout(icon: "gauge.with.dots.needle.67percent", title: AppInfo.name) {
            VStack(alignment: .leading, spacing: 14) {
                point("waveform.path.ecg", "Live data from your car's own systems")
                point("battery.100percent.bolt", "A detailed battery health report, with PDF")
                point("stopwatch", "0–60, quarter mile, braking and lap timing")
                point("exclamationmark.triangle", "Read and clear trouble codes")
                point("bolt.car", "Charge curves as you charge")
            }
        }
        .safeAreaInset(edge: .bottom) { next() }
    }

    private var adapter: some View {
        pageLayout(icon: "cable.connector", title: "What you need") {
            VStack(alignment: .leading, spacing: 14) {
                Text("A Bluetooth LE (or Wi-Fi) ELM327 OBD adapter, such as the Veepeak OBDCheck BLE, OBDLink CX or vLinker MC+.")
                Text("Plug it into the OBD port, usually under the dashboard by the driver's knees, and switch the car on.")
                Text("Classic Bluetooth adapters don't work with iPhone.").foregroundStyle(.secondary)
            }
            .font(.body)
        }
        .safeAreaInset(edge: .bottom) { next() }
    }

    private var car: some View {
        VStack(spacing: 12) {
            Text("Your car")
                .font(.largeTitle.weight(.bold))
                .padding(.top, 30)
            Text("It's detected when you connect; pick it now to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            CarPicker(prefs: prefs) { page = 3 }
                .scrollContentBackground(.hidden)
            Spacer(minLength: 40)
        }
    }

    private var safety: some View {
        pageLayout(icon: "exclamationmark.shield", title: "Drive safely") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Performance timing is for closed roads, tracks and drag strips only. Never on public roads.")
                Text("Mount your phone and don't touch it while driving: runs start and stop by themselves.")
                Text("Readings and battery reports are estimates from the car's OBD data, not a manufacturer's diagnosis.")
                    .foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                Button {
                    finish()
                } label: {
                    Text("I understand").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                Button("Try the demo car first") {
                    finish()
                    obd.startDemo()
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 50)
            .background(.black)
        }
    }

    private func point(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(.orange).frame(width: 30)
            Text(text)
        }
    }

    private func finish() {
        prefs.acceptedTrackUse = true
        prefs.onboarded = true
    }
}
