/// Release identity shared by the app, About panel, CLI, and packaging.
public enum AppVersion {
    public static let number = "1.0.0"
    public static let channel = "beta"
    public static var display: String {
        channel.isEmpty ? number : "\(number) \(channel)"
    }
}
