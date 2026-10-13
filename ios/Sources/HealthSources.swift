import SwiftUI

enum HealthSource: String, CaseIterable, Identifiable {
    case restingEstimate, restingEnergy, activeEnergy, bmi, weightChange, forbes, ace, water, diet, portions

    var id: String { rawValue }
    static let energy: [Self] = [.restingEstimate, .restingEnergy, .activeEnergy]
    static let projections: [Self] = energy + [.bmi, .weightChange, .forbes]
    static let bodyFat: [Self] = [.forbes, .weightChange, .ace]
    static let nutrition: [Self] = [.diet, .portions, .water]

    var title: String {
        switch self {
        case .restingEstimate: "Mifflin & St Jeor — resting energy (1990)"
        case .restingEnergy: "Apple Health — resting energy"
        case .activeEnergy: "Apple Health — active energy"
        case .bmi: "CDC — adult BMI categories"
        case .weightChange: "Hall — energy deficit and weight loss (2008)"
        case .forbes: "Hall — Forbes body-composition model (2007)"
        case .ace: "ACE — body-fat categories (2014)"
        case .water: "EFSA — Dietary Reference Values for Water (2010)"
        case .diet: "WHO — Healthy diet"
        case .portions: "NHS — 5 A Day portion sizes"
        }
    }

    var explanation: String {
        switch self {
        case .restingEstimate:
            "The fallback uses the Mifflin–St Jeor equation: 10 × weight in kg + 6.25 × height in cm − 5 × age, with +5 for Male or −161 for Female. 00Food substitutes age 35; Neutral uses the midpoint (−78). These substitutions are app assumptions, not a validated variant of the equation."
        case .restingEnergy:
            "Apple defines resting energy as energy burned at rest. 00Food averages available resting totals from the last seven completed days, requiring at least five readable days. This averaging rule is an app choice."
        case .activeEnergy:
            "Apple defines active energy as energy burned through activity, excluding resting energy. 00Food adds active and resting energy once to estimate total daily energy expenditure (TDEE)."
        case .bmi:
            "BMI = weight in kg / height in metres squared. CDC's adult healthy-weight category is 18.5 to less than 25. 00Food displays 18.5–24.9 and converts those boundaries to weight at your height. BMI is a screening measure, not a diagnosis or an individual target."
        case .weightChange:
            "The dotted weight illustration uses the traditional approximation of 7,700 kcal per kg (about 3,500 kcal per lb). Hall discusses this rule and why actual weight change differs with body composition and adaptation. 00Food holds recent expenditure constant for comparison; the line and threshold dates are illustrations, not predictions."
        case .forbes:
            "Hall revisits Forbes's relationship between fat and fat-free mass. 00Food estimates the fat share of sustained weight loss as FM / (FM + 10.4), where FM is fat mass in kg, and recalculates as fat mass decreases. It starts from a seven-day median of available body-fat and weight readings, an app smoothing choice. Daily scale drops are not treated as measured fat loss; water and glycogen changes cannot be separated."
        case .ace:
            "The body-fat chart uses ACE's sex-specific category boundaries. Category names and crossing dates describe a reference classification, not a diagnosis or a recommended personal body-fat target."
        case .water:
            "EFSA's adequate total water intake is 2 litres for adult women and 2.5 litres for adult men in moderate conditions, including water from food and all beverages. 00Food's eight 250 mL glasses are a fluid-tracking goal, not a personalised EFSA prescription. Needs can increase with exercise or heat."
        case .diet:
            "WHO recommends at least 400 g of fruit and vegetables per day for adults and describes variety and balance across food groups. These are the general references for 5-a-day tracking and daily-review nutrition guidance. Reviews reflect the foods logged and cannot establish nutrient adequacy or deficiency."
        case .portions:
            "NHS defines a typical adult fruit or vegetable portion as 80 g and explains what counts toward 5 A Day. The app's portion flags are directional estimates rather than measured nutrient totals."
        }
    }

    var url: URL {
        let address: String = switch self {
        case .restingEstimate: "https://pubmed.ncbi.nlm.nih.gov/2305711/"
        case .restingEnergy: "https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/basalenergyburned"
        case .activeEnergy: "https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/activeenergyburned"
        case .bmi: "https://www.cdc.gov/bmi/adult-calculator/bmi-categories.html"
        case .weightChange: "https://pmc.ncbi.nlm.nih.gov/articles/PMC2376744/"
        case .forbes: "https://pmc.ncbi.nlm.nih.gov/articles/PMC2376748/"
        case .ace: "https://www.acefitness.org/fitness-certifications/ace-answers/exam-preparation-blog/3815/anthropometric-measurements-when-to-use-this-assessment/"
        case .water: "https://www.efsa.europa.eu/en/efsajournal/pub/1459"
        case .diet: "https://www.who.int/news-room/fact-sheets/detail/healthy-diet"
        case .portions: "https://www.nhs.uk/live-well/eat-well/5-a-day/portion-sizes/"
        }
        return URL(string: address)!
    }
}

struct HealthSourceLinks: View {
    let sources: [HealthSource]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sources").font(.subheadline.weight(.semibold))
            ForEach(sources) { source in
                Link(source.title, destination: source.url).font(.subheadline)
            }
        }
    }
}

struct HealthSourcesView: View {
    var sources: [HealthSource] = HealthSource.allCases
    var body: some View {
        Form {
            Section("How 00Food uses these sources") {
                Text("Your calorie allowance is (resting + active energy) × (1 − your chosen deficit). Maintain (0%), Gentle (10%), Balanced (15%) and Faster (20%) are app controls, not medical recommendations. The reference papers do not validate a personalised target, the app's smoothing rules, or its forecasts.")
                    .font(.subheadline)
            }
            ForEach(sources) { source in
                Section {
                    Text(source.explanation).font(.subheadline)
                    Link("Read source ↗", destination: source.url)
                        .accessibilityLabel("Read \(source.title)")
                } header: { Text(source.title).textCase(nil) }
            }
        }
        .navigationTitle("Health sources")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct HealthSourcesButton: View {
    var title = "Sources"
    var sources: [HealthSource] = HealthSource.allCases
    @State private var showingSources = false
    var body: some View {
        Button { showingSources = true } label: {
            Label(title, systemImage: "book")
        }
        .font(.footnote)
        .buttonStyle(.borderless)
        .accessibilityLabel("\(title), health information references")
        .sheet(isPresented: $showingSources) {
            NavigationStack {
                HealthSourcesView(sources: sources)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showingSources = false }
                    } }
            }
        }
    }
}
