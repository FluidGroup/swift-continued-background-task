
public struct BackgroundTaskRequiredResources: OptionSet, Sendable {
  
  public let rawValue: Int
  
  public init(rawValue: Int) {
    self.rawValue = rawValue
  }
  
  public static let gpu = BackgroundTaskRequiredResources(rawValue: 1 << 0)
 
}
