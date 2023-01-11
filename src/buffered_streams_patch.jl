# This fix did not make it into the most recent version of BufferedStreams (1.1.0)
using BufferedStreams

function Base.position(s::BufferedOutputStream)
    return max(0, position(s.sink) + s.position - 1)
end