import FoundationCompat

// Keep upstream's UserDefaults calls while replacing Linux Foundation's persistence.
typealias UserDefaults = SQLiteUserDefaults
