import Foundation

/// The app's tabs, for the tour to switch between.
public enum AppTab: String, Codable, CaseIterable, Sendable {
    case car, rules, scanner, settings
}

/// Screens the tour can open with "Show me".
public enum GuideScreen: String, Codable, CaseIterable, Sendable {
    case charging, offPeak, chargers, energy, batteryHealth
    case planTrip, foodChains, trafficAhead, commute, timeAtPlaces
    case places, alerts, activity
}

public struct GuideStep: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    public var symbol: String
    public var tab: AppTab
    public var screen: GuideScreen?

    public init(_ id: String, _ title: String, _ body: String, symbol: String, tab: AppTab, screen: GuideScreen? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.symbol = symbol
        self.tab = tab
        self.screen = screen
    }
}

public struct GuideSection: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var symbol: String
    public var steps: [GuideStep]
}

/// One update's worth of new things, pointing at the tour steps that explain them.
public struct GuideRelease: Identifiable, Equatable, Sendable {
    /// Goes up by one with every update that adds something to show.
    public var number: Int
    public var title: String
    public var stepIds: [String]
    public var id: Int { number }

    public var steps: [GuideStep] { stepIds.compactMap(Guide.step) }
}

/// The tour and what's new. When a build adds or changes something you'd use, add or update its step
/// and put a new release at the top of `releases`.
public enum Guide {
    public static let sections: [GuideSection] = [
        GuideSection(id: "car", title: "Your car", symbol: "car.fill", steps: [
            GuideStep("car.dashboard", "Your car at a glance",
                      "Charge, range, plug, locks and climate, from the car's last report. The line under the card says how old that report is.",
                      symbol: "gauge.with.dots.needle.67percent", tab: .car),
            GuideStep("car.refresh", "Refresh, or a full refresh",
                      "The button at the top right. Refresh reads Kia's last copy, which can be a few minutes old. Full refresh from the car wakes it for up-to-the-minute figures: it takes up to 30 seconds and uses a little 12 V charge, so save it for when you need it. Pulling down does a normal refresh.",
                      symbol: "arrow.clockwise", tab: .car),
            GuideStep("car.controls", "Controls",
                      "Climate, locks, charging and the charge limit. After you tap one, the tile waits until the car confirms it did it, like the Kia app.",
                      symbol: "square.grid.2x2", tab: .car),
            GuideStep("car.climate", "Climate",
                      "Scroll down to Climate. Slide to pick 17–27 °C (the EV6 won't take anything outside that). It's used by the Climate tile, widgets, Siri and the Watch. Climate runs for 15 minutes. Turn on defrost and the heated wheel and mirrors here, and Don't start charging stops climate kicking off a charge while you're plugged in.",
                      symbol: "thermometer.medium", tab: .car),
            GuideStep("car.liveActivity", "On the Lock Screen",
                      "While climate runs or the car charges, a Live Activity shows the countdown or progress on the Lock Screen and in the Dynamic Island.",
                      symbol: "platter.filled.bottom.iphone", tab: .car),
        ]),
        GuideSection(id: "charging", title: "Charging", symbol: "bolt.fill", steps: [
            GuideStep("charging.hub", "Charging & costs",
                      "Your home tariff (Octopus Agile prices come in on their own), smart charging to be full by a set time at the cheapest rate, and what every charge cost, home and public.",
                      symbol: "bolt.batteryblock", tab: .car, screen: .charging),
            GuideStep("charging.offPeak", "Off-peak window",
                      "The car's own charging window, like the 23:00–06:00 you set in the Kia app. Change the times, or make it charge only in the window, and send it to the car. Your departure times aren't touched. It asks for your Kia Connect PIN the first time.",
                      symbol: "moon.stars", tab: .car, screen: .offPeak),
            GuideStep("charging.plugAlerts", "Plugged in? Charging?",
                      "When you plug in, you get a note saying when it'll charge (\"All set for tomorrow\"). If it's plugged in but hasn't started 20 minutes into the off-peak window, you're told, in case the charger wasn't confirmed in its app. And at 21:00, if it isn't plugged in, a reminder you can ignore. Change the time in Settings › Alerts.",
                      symbol: "powerplug.fill", tab: .settings, screen: .alerts),
            GuideStep("charging.chargers", "Chargers nearby",
                      "Chargers around the car with speeds, connectors, prices and drivers' check-ins. With a Google key, how many are free right now and reviews.",
                      symbol: "ev.charger", tab: .car, screen: .chargers),
            GuideStep("charging.energy", "Energy and battery health",
                      "Energy use shows your miles per kWh over the last month. Battery health keeps a history of what the car reports.",
                      symbol: "chart.bar.xaxis", tab: .car, screen: .energy),
        ]),
        GuideSection(id: "trips", title: "Trips", symbol: "map.fill", steps: [
            GuideStep("trips.plan", "Plan a trip",
                      "Car tab › Trips › Plan a trip. Pick where you're going and when you leave. It plans the charging stops, how long each takes, and what you'll arrive with. It can also set smart charging so you leave with enough.",
                      symbol: "map", tab: .car, screen: .planTrip),
            GuideStep("trips.food", "Charge and eat",
                      "Under each charging stop is a line showing which of your food places are a short walk away, and roughly when you'll get there. Tap it to see every charger you could use for that stop, with the food at each. Pick one and the trip is planned around it. Change your food list in Food I look for.",
                      symbol: "fork.knife", tab: .car, screen: .foodChains),
            GuideStep("trips.saved", "Save it, send it to the car",
                      "At the bottom of a planned trip: Save this trip keeps it (it's listed at the top of Plan a trip), and Send to the car puts the stops and destination in the car's sat nav, now or whenever you're ready.",
                      symbol: "car.side.arrowtriangle.up.fill", tab: .car, screen: .planTrip),
            GuideStep("trips.traffic", "Traffic ahead",
                      "On the move, pick where you're heading (the last place sent to the car is already there). It shows the traffic on the rest of the drive and other ways to go. Choose one and send it to the car. Kia doesn't share where the car's sat nav is going, so it's picked here.",
                      symbol: "exclamationmark.triangle", tab: .car, screen: .trafficAhead),
            GuideStep("trips.commute", "Commute",
                      "Add your routes home by pasting their Google Maps links, favourite first. It checks the traffic on all of them, takes your favourite unless another is much quicker, and writes your ETA message (\"I'll be home at 18:38…\") ready to send.",
                      symbol: "car.rear.road.lane", tab: .car, screen: .commute),
            GuideStep("trips.commuteAuto", "Commute on autopilot",
                      "In Shortcuts › Automation, make one for when you leave work (or a time on weekdays), set to Run Immediately. Add Check my commute from EV6, then Send Message with its result. You get a notification saying which way to go, and your message goes by itself.",
                      symbol: "wand.and.stars", tab: .car, screen: .commute),
            GuideStep("trips.places", "Time at places",
                      "How long the car was at each of your places on any day, from its own trips: handy for timesheets.",
                      symbol: "clock.badge.checkmark", tab: .car, screen: .timeAtPlaces),
        ]),
        GuideSection(id: "rules", title: "Rules", symbol: "list.bullet.rectangle", steps: [
            GuideStep("rules.intro", "Rules",
                      "Automatic climate and charging. Type what you want, like \"weekdays at 7:30 heat to 22 if it's below 5\", or start from a template. Rules can use the weather, your places and the car's charge.",
                      symbol: "list.bullet.rectangle", tab: .rules),
            GuideStep("rules.ask", "Ask first",
                      "A rule can ask instead of just starting. At its time you get a notification to Start now, In 15 min or Not today. It's skipped when the weather means it isn't needed.",
                      symbol: "questionmark.bubble", tab: .rules),
            GuideStep("rules.schedules", "Rules at set times",
                      "iOS can't wake an app at an exact time, so timed rules run from a Shortcuts automation. Rules › Set up schedule automations shows what to add.",
                      symbol: "calendar.badge.clock", tab: .rules),
            GuideStep("rules.places", "Places",
                      "Add Home and Work so rules can start climate when you leave or arrive, and so Time at places knows where you were.",
                      symbol: "mappin.and.ellipse", tab: .rules, screen: .places),
        ]),
        GuideSection(id: "scanner", title: "Scanner", symbol: "stethoscope", steps: [
            GuideStep("scanner.intro", "The OBD scanner",
                      "With a Bluetooth OBD adapter plugged in: live data from the car's modules, cell voltages and battery health, trouble codes, a performance timer, a trip computer, and recordings you can open in Numbers or Excel.",
                      symbol: "stethoscope", tab: .scanner),
        ]),
        GuideSection(id: "everywhere", title: "Beyond the app", symbol: "apps.iphone", steps: [
            GuideStep("extras.widgets", "Widgets, Watch and Siri",
                      "Home and Lock Screen widgets with buttons, Control Center controls, the Apple Watch app and complications, and Siri and Shortcuts actions: start climate, lock, check the car, charge limit, check my commute.",
                      symbol: "apps.iphone", tab: .car),
        ]),
        GuideSection(id: "settings", title: "Settings", symbol: "gearshape.fill", steps: [
            GuideStep("settings.account", "Kia account and safety",
                      "Your Kia sign-in, the minimum charge the app won't run climate below, and how many Kia requests automation may use in a day.",
                      symbol: "person.badge.key", tab: .settings),
            GuideStep("settings.alerts", "Alerts and the activity log",
                      "Alerts for charging finishing or stopping early, the car left unlocked or a window open, low tyres, a weak 12 V battery and low charge. The activity log shows everything the app did and why.",
                      symbol: "bell.badge", tab: .settings, screen: .alerts),
            GuideStep("settings.keys", "Charger and traffic data",
                      "Optional keys: Open Charge Map for charger speeds and details, and Google for live charger availability, reviews and traffic. For traffic, turn on the Routes API for the Google key.",
                      symbol: "key", tab: .settings),
            GuideStep("settings.guide", "This guide",
                      "Settings › Guide. What's new appears after each update, and you can rerun the whole tour or any section whenever you like.",
                      symbol: "graduationcap", tab: .settings),
        ]),
    ]

    /// Newest first.
    public static let releases: [GuideRelease] = [
        GuideRelease(number: 6, title: "Plug-in checks", stepIds: ["charging.plugAlerts"]),
        GuideRelease(number: 5, title: "Food on the way, and this guide", stepIds: ["trips.food", "trips.saved", "settings.guide"]),
        GuideRelease(number: 4, title: "Traffic ahead", stepIds: ["trips.traffic"]),
        GuideRelease(number: 3, title: "Commute", stepIds: ["trips.commute", "trips.commuteAuto"]),
        GuideRelease(number: 2, title: "Off-peak charging, full refresh and the temperature slider",
                     stepIds: ["car.climate", "car.refresh", "charging.offPeak", "car.liveActivity"]),
    ]

    public static var latest: Int { releases.map(\.number).max() ?? 0 }

    public static var allSteps: [GuideStep] { sections.flatMap(\.steps) }

    public static func step(_ id: String) -> GuideStep? { allSteps.first { $0.id == id } }

    /// Updates since the one you last saw, newest first.
    public static func unseen(since seen: Int) -> [GuideRelease] {
        releases.filter { $0.number > seen }
    }
}
