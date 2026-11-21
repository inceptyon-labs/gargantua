import Testing

/// Every suite that runs the real `hdiutil` is nested here so they run one at
/// a time. Run in parallel, several creates and attaches at once make the
/// disk-image helper refuse with "Resource temporarily unavailable" for longer
/// than the verifier's attach retries wait: CI hit it with five suites
/// attaching in the same second.
@Suite(.serialized)
enum RealDiskImageTests {}
