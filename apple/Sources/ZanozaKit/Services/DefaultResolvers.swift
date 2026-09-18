import Foundation

// Default list of recursive resolvers used when AppSettings.customResolvers
// is empty. Curated to Yandex DNS only as a broadly reachable bootstrap pool;
// performance is network-specific and the false.actor server currently caps
// negotiated download MTU at 2048. Users should import and evaluate their own
// operator-local pool in the per-profile resolver manager.
public enum DefaultResolvers {
    public static let text: String = """
    # Yandex
    77.88.8.8
    77.88.8.7
    77.88.8.1
    77.88.8.2
    77.88.8.3
    77.88.8.88
    """
}
