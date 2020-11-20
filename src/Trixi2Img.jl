module Trixi2Img

# Include other packages
using EllipsisNotation
using Glob: glob
using HDF5: h5open, attributes, haskey
using Plots: plot, plot!, gr, savefig, contourf!
using TimerOutputs
import GR

# Number of spatial dimensions
"""
    ndims

Number of spatial dimensions (= 2).
"""
const ndim = 2

# Include all source files
include("interpolation.jl")
include("interpolate.jl")
include("io.jl")

# Include top-level conversion method
include("convert.jl")

# export types/functions that define the public API of Trixi2Img
export trixi2img

end # module Trixi2Img

