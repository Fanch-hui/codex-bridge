import Foundation

extension ACPJSONValue {
  public var isProgressDisplayOmitted: Bool {
    self["_bridgeDisplayOmitted"]?.boolValue == true
  }

  public var progressOmissionDisplay: String? {
    isProgressDisplayOmitted ? self["display"]?.stringValue : nil
  }

  /// A presentation placeholder cannot stand in for an original approval input.
  public var originalProgressInput: ACPJSONValue? {
    isProgressDisplayOmitted ? nil : self
  }
}
