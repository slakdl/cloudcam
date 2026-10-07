/// The looks the app can switch between. (The name is left over from the first look; the
/// mode names are also what the website groups photos by.)
enum CloudLook {
    enum Mode: String, CaseIterable, Identifiable {
        case spider = "Spider"
        case pixel = "Pixel"
        case web = "Web"

        var id: String { rawValue }
    }
}
