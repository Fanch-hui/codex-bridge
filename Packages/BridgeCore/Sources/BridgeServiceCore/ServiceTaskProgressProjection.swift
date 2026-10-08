enum ServiceTaskProgressProjection {
  static func changedFiles(_ paths: [String]) throws -> [String] {
    for path in paths {
      try ServiceValidation.relativePath(path, field: "task.changedFiles")
    }
    return Array(Set(paths).sorted().prefix(200))
  }
}
