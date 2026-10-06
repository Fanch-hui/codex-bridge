public enum AgentModelMatcher {
  public static func match<Model>(
    _ modelID: String, in models: [Model],
    id: (Model) -> String, compatibleIDs: (Model) -> [String]
  ) -> Model? {
    models.first(where: { id($0) == modelID })
      ?? models.first(where: { compatibleIDs($0).contains(modelID) })
  }

  public static func match(_ modelID: String, in models: [AgentModelDescriptor])
    -> AgentModelDescriptor?
  {
    match(modelID, in: models, id: { $0.id }, compatibleIDs: { $0.compatibleModelIDs })
  }
}
