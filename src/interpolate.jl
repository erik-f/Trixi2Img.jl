# Convert cell-centered values to node-centered values by averaging over all
# four neighbors and making use of the periodicity of the solution
function cell2node(cell_centered_data::AbstractArray{Float64})
  # Create temporary data structure to make the averaging algorithm as simple
  # as possible (by using a ghost layer)
  tmp = similar(cell_centered_data, size(cell_centered_data) .+ (2, 2, 0))

  # Fill center with original data
  tmp[2:end-1, 2:end-1, :] .= cell_centered_data

  # Fill sides with opposite data (periodic domain)
  # x-direction
  tmp[1,   2:end-1, :] .= cell_centered_data[end, :, :]
  tmp[end, 2:end-1, :] .= cell_centered_data[1,   :, :]
  # y-direction
  tmp[2:end-1, 1,   :] .= cell_centered_data[:, end, :]
  tmp[2:end-1, end, :] .= cell_centered_data[:, 1,   :]
  # Corners
  tmp[1,   1,   :] = cell_centered_data[end, end, :]
  tmp[end, 1,   :] = cell_centered_data[1,   end, :]
  tmp[1,   end, :] = cell_centered_data[end, 1,   :]
  tmp[end, end, :] = cell_centered_data[1,   1,   :]

  # Create output data structure
  resolution_in, _, n_variables = size(cell_centered_data)
  resolution_out = resolution_in + 1
  node_centered_data = Array{Float64}(undef, resolution_out, resolution_out, n_variables)

  # Obtain node-centered value by averaging over neighboring cell-centered values
  for j in 1:resolution_out
    for i in 1:resolution_out
      node_centered_data[i, j, :] = (tmp[i,   j,   :] +
                                     tmp[i+1, j,   :] +
                                     tmp[i,   j+1, :] +
                                     tmp[i+1, j+1, :]) / 4
    end
  end

  return node_centered_data
end


# Convert 3d unstructured data to 2d slice.
# Additional to the new unstructured data updated coordinates, levels and
# center coordinates are returned.
function unstructured_2d_to_3d(unstructured_data::AbstractArray{Float64},
                               coordinates::AbstractArray{Float64},
                               levels::AbstractArray{Int}, length_level_0::Float64,
                               center_level_0::AbstractArray{Float64},
                               slice_axis, slice_axis_intersect)

  dimensions = Dict(
    :x => 1,
    :y => 2,
    :z => 3
  )
  if !haskey(dimensions, slice_axis)
    supported_dims = keys(dimensions)
    error("illegal dimension '$slice_axis', supported dimensions are $supported_dims")
  end
  slice_axis_dimension = dimensions[slice_axis]
  other_dimensions = [1, 2, 3][1:end .!= slice_axis_dimension]

  # Extract data shape information
  n_nodes_in, _, _, n_elements, n_variables = size(unstructured_data)

  # Get node coordinates for DG locations on reference element
  nodes_in, _ = gauss_lobatto_nodes_weights(n_nodes_in)

  # New unstructured data has one dimension less.
  # The redundant element ids are removed later.
  new_unstructured_data = similar(unstructured_data[1, ..])

  # Declare new empty arrays to fill in new coordinates and levels
  new_coordinates = Array{Float64}(undef, 2, 0)
  new_levels = Array{eltype(levels)}(undef, 0)

  # Counter for new element ids
  new_id = 0

  # Save vandermonde matrices in a Dict to prevent redundant generation
  vandermonde_to_2d = Dict()

  # Limits of domain in slice_axis dimension
  lower_limit = center_level_0[slice_axis_dimension] - length_level_0 / 2
  upper_limit = center_level_0[slice_axis_dimension] + length_level_0 / 2

  if slice_axis_intersect < lower_limit || slice_axis_intersect > upper_limit
    error("slice_axis_intersect $slice_axis_intersect outside of domain")
  end

  for element_id in 1:n_elements
    # Distance from center to border of this element (half the length)
    element_length = length_level_0 / 2^levels[element_id]
    first_coordinate = coordinates[:, element_id] .- element_length / 2
    last_coordinate = coordinates[:, element_id] .+ element_length / 2

    # Check if slice plane and current element intersect
    # The upper limit check is needed because of the > in the first check
    if (first_coordinate[slice_axis_dimension] <= slice_axis_intersect &&
          last_coordinate[slice_axis_dimension] > slice_axis_intersect) ||
        (slice_axis_intersect == upper_limit &&
          last_coordinate[slice_axis_dimension] == upper_limit)
      # This element is of interest
      new_id += 1

      # Add element to new coordinates and levels
      new_coordinates = hcat(new_coordinates, coordinates[other_dimensions, element_id])
      push!(new_levels, levels[element_id])

      # Construct vandermonde matrix (or load from Dict if possible)
      normalized_intersect =
          (slice_axis_intersect - first_coordinate[slice_axis_dimension]) /
          element_length * 2 - 1

      if haskey(vandermonde_to_2d, normalized_intersect)
        vandermonde = vandermonde_to_2d[normalized_intersect]
      else
        # Generate vandermonde matrix to interpolate values at nodes_in to one value
        vandermonde = polynomial_interpolation_matrix(nodes_in, [normalized_intersect])
        vandermonde_to_2d[normalized_intersect] = vandermonde
      end

      # 1D interpolation to specified slice plane
      for i in 1:n_nodes_in
        for ii in 1:n_nodes_in
          if slice_axis == :x
            data = unstructured_data[:, i, ii, element_id, :]
          elseif slice_axis == :y
            data = unstructured_data[i, :, ii, element_id, :]
          elseif slice_axis == :z
            data = unstructured_data[i, ii, :, element_id, :]
          end
          value = interpolate_nodes(permutedims(data), vandermonde, n_variables)
          new_unstructured_data[i, ii, new_id, :] = value[:, 1]
        end
      end
    end
  end

  # Remove redundant element ids
  unstructured_data = new_unstructured_data[:, :, 1:new_id, :]

  center_level_0 = center_level_0[other_dimensions]

  return unstructured_data, new_coordinates, new_levels, center_level_0
end


# Interpolate unstructured DG data to structured data (cell-centered)
function unstructured2structured(unstructured_data::AbstractArray{Float64},
                                 normalized_coordinates::AbstractArray{Float64},
                                 levels::AbstractArray{Int}, resolution::Int,
                                 nvisnodes_per_level::AbstractArray{Int})
  # Extract data shape information
  n_nodes_in, _, n_elements, n_variables = size(unstructured_data)

  # Get node coordinates for DG locations on reference element
  nodes_in, _ = gauss_lobatto_nodes_weights(n_nodes_in)

  #=# Calculate node coordinates for structured locations on reference element=#
  #=max_level = length(nvisnodes_per_level) - 1=#
  #=visnodes_per_level = []=#
  #=for l in 0:max_level=#
  #=  n_nodes_out = nvisnodes_per_level[l + 1]=#
  #=  dx = 2 / n_nodes_out=#
  #=  push!(visnodes_per_level, collect(range(-1 + dx/2, 1 - dx/2, length=n_nodes_out)))=#
  #=end=#

  # Calculate interpolation vandermonde matrices for each level
  max_level = length(nvisnodes_per_level) - 1
  vandermonde_per_level = []
  for l in 0:max_level
    n_nodes_out = nvisnodes_per_level[l + 1]
    dx = 2 / n_nodes_out
    nodes_out = collect(range(-1 + dx/2, 1 - dx/2, length=n_nodes_out))
    push!(vandermonde_per_level, polynomial_interpolation_matrix(nodes_in, nodes_out))
  end

  # For each element, calculate index position at which to insert data in global data structure
  lower_left_index = element2index(normalized_coordinates, levels, resolution, nvisnodes_per_level)

  # Create output data structure
  structured = Array{Float64}(undef, resolution, resolution, n_variables)

  # For each variable, interpolate element data and store to global data structure
  for v in 1:n_variables
    # Reshape data array for use in interpolate_nodes function
    reshaped_data = reshape(unstructured_data[:, :, :, v], 1, n_nodes_in, n_nodes_in, n_elements)

    for element_id in 1:n_elements
      # Extract level for convenience
      level = levels[element_id]

      # Determine target indices
      n_nodes_out = nvisnodes_per_level[level + 1]
      first = lower_left_index[:, element_id]
      last = first .+ (n_nodes_out - 1)

      # Interpolate data
      vandermonde = vandermonde_per_level[level + 1]
      structured[first[1]:last[1], first[2]:last[2], v] .= (
          reshape(interpolate_nodes(reshaped_data[:, :, :, element_id], vandermonde, 1),
                  n_nodes_out, n_nodes_out))
    end
  end

  return structured
end


# For a given normalized element coordinate, return the index of its lower left
# contribution to the global data structure
function element2index(normalized_coordinates::AbstractArray{Float64}, levels::AbstractArray{Int},
                       resolution::Int, nvisnodes_per_level::AbstractArray{Int})
  n_elements = length(levels)

  # First, determine lower left coordinate for all cells
  dx = 2 / resolution
  lower_left_coordinate = Array{Float64}(undef, ndim, n_elements)
  for element_id in 1:n_elements
    nvisnodes = nvisnodes_per_level[levels[element_id] + 1]
    lower_left_coordinate[1, element_id] = (
        normalized_coordinates[1, element_id] - (nvisnodes - 1)/2 * dx)
    lower_left_coordinate[2, element_id] = (
        normalized_coordinates[2, element_id] - (nvisnodes - 1)/2 * dx)
  end

  # Then, convert coordinate to global index
  indices = coordinate2index(lower_left_coordinate, resolution)

  return indices
end


# Find 2D array index for a 2-tuple of normalized, cell-centered coordinates (i.e., in [-1,1])
function coordinate2index(coordinate, resolution::Integer)
  # Calculate 1D normalized coordinates
  dx = 2/resolution
  mesh_coordinates = collect(range(-1 + dx/2, 1 - dx/2, length=resolution))

  # Find index
  id_x = searchsortedfirst.(Ref(mesh_coordinates), coordinate[1, :], lt=(x,y)->x .< y .- dx/2)
  id_y = searchsortedfirst.(Ref(mesh_coordinates), coordinate[2, :], lt=(x,y)->x .< y .- dx/2)
  return transpose(hcat(id_x, id_y))
end

#=function coordinate2index(coordinate, resolution::Integer)=#
#=  # Calculate 1D normalized coordinates=#
#=  dx = 2/resolution=#
#=  mesh_coordinates = collect(range(-1 + dx/2, 1 - dx/2, length=resolution))=#
#==#
#=  # Prepare output storage=#
#=  n_elements = size(coordinate)[2]=#
#=  indices = Array{Int}(undef, ndim, n_elements)=#
#==#
#=  # Find indicex=#
#=  for element_id in 1:n_elements=#
#=    indices[1] = searchsortedfirst(mesh_coordinates, coordinate[1, element_id], lt=(x,y)->x .< y .- dx/2)=#
#=    indices[2] = searchsortedfirst(mesh_coordinates, coordinate[2, element_id], lt=(x,y)->x .< y .- dx/2)=#
#=  end=#
#==#
#=  return hcat(id_x, id_y)=#
#=end=#


# Find 2D array index for a 2-tuple of normalized, cell-centered coordinates (i.e., in [-1,1])
#=function coordinate2index(coordinate, resolution::Integer)=#
#=  # Calculate 1D normalized coordinates=#
#=  dx = 2/resolution=#
#=  mesh_coordinates = collect(range(-1 + dx/2, 1 - dx/2, length=resolution))=#
#==#
#=  # Build mesh for nearest neighbor search=#
#=  mesh = Array{Float64}(undef, ndim, resolution, resolution)=#
#=  for j in 1:resolution=#
#=    for i in 1:resolution=#
#=      mesh[1, i, j] = mesh_coordinates[i]=#
#=      mesh[2, i, j] = mesh_coordinates[j]=#
#=    end=#
#=  end=#
#==#
#=  # Create tree=#
#=  tree = KDTree(mesh, leafsize=10)=#
#==#
#=  # Find index in a nearest-neighbor search=#
#=  index, _ = knn(tree, coordinate, 1)=#
#=end=#


function interpolate_data(data_in::AbstractArray, n_nodes_in::Integer, n_nodes_out::Integer)
  # Get node coordinates for input and output locations on reference element
  nodes_in, _ = gauss_lobatto_nodes_weights(n_nodes_in)
  dx = 2/n_nodes_out
  #=nodes_out = collect(range(-1 + dx/2, 1 - dx/2, length=n_nodes_out))=#
  nodes_out = collect(range(-1, 1, length=n_nodes_out))

  # Get interpolation matrix
  vandermonde = polynomial_interpolation_matrix(nodes_in, nodes_out)

  # Create output data structure
  n_elements = div(size(data_in, 1), n_nodes_in^ndim)
  n_variables = size(data_in, 2)
  data_out = Array{eltype(data_in)}(undef, n_nodes_out, n_nodes_out, n_elements, n_variables)

  for n in 1:1
  # Interpolate each variable separately
  for v = 1:n_variables
    # Reshape data to fit expected format for interpolation function
    # FIXME: this "reshape here, reshape later" funny business should be implemented properly
    reshaped = reshape(data_in[:, v], 1, n_nodes_in, n_nodes_in, n_elements)

    # Interpolate data for each cell
    for element_id = 1:1#n_elements
      data_out[:, :, element_id, v] = interpolate_nodes(reshaped[:, :, :, element_id],
                                                        vandermonde, 1)
    end
  end
  end

  return reshape(data_out, n_nodes_out^ndim * n_elements, n_variables)
end


function calc_vertices(coordinates::AbstractArray{Float64, 2},
                       levels::AbstractArray{Int}, length_level_0::Float64)
  @assert ndim == 2 "Algorithm currently only works in 2D"

  # Initialize output arrays
  n_elements = length(levels)
  x = Array{Float64, 2}(undef, 2^ndim+1, n_elements)
  y = Array{Float64, 2}(undef, 2^ndim+1, n_elements)

  # Calculate vertices for all coordinates at once
  for element_id in 1:n_elements
    length = length_level_0 / 2^levels[element_id]
    x[1, element_id] = coordinates[1, element_id] - 1/2 * length
    x[2, element_id] = coordinates[1, element_id] + 1/2 * length
    x[3, element_id] = coordinates[1, element_id] + 1/2 * length
    x[4, element_id] = coordinates[1, element_id] - 1/2 * length
    x[5, element_id] = coordinates[1, element_id] - 1/2 * length

    y[1, element_id] = coordinates[2, element_id] - 1/2 * length
    y[2, element_id] = coordinates[2, element_id] - 1/2 * length
    y[3, element_id] = coordinates[2, element_id] + 1/2 * length
    y[4, element_id] = coordinates[2, element_id] + 1/2 * length
    y[5, element_id] = coordinates[2, element_id] - 1/2 * length
  end

  return x, y
end
