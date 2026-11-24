// A made-up print: a unit vector along one axis, turned toward another so it sits the given cosine distance from the axis.
func voicePrint(_ axis: Int, distance: Float = 0, toward other: Int = 255) -> [Float] {
    var values = [Float](repeating: 0, count: 256)
    values[axis] = 1 - distance
    values[other] = (1 - (1 - distance) * (1 - distance)).squareRoot()
    return values
}
