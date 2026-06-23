# encoding: utf-8
=begin
##Author : Wikii
##Date    :20090207
##Ver     :0.04

v0.04 20090210
1 if path started at a vertex of profile,the vertex will be treated as align point.
2 auto reverse face to get directviewing result.

v0.03 20090209
1 start at nearest vertex when path is closed
2 fix some bugs

v0.02 20090208
1 perfect ending;
2 autosmooth
=end

module F3DFAK
VERSION = 'dev155'
  class Face

    def wi_center
      vertices_positions = vertices.map { |vertex| vertex.position }
      vx = vertices_positions.map { |point| point.x }.wi_average
      vy = vertices_positions.map { |point| point.y }.wi_average
      vz = vertices_positions.map { |point| point.z }.wi_average
      Geom::Point3d.new([vx, vy, vz])
    end
  end

  class Follow_me_keep_z
    @wikii_push_pull_recodes = []
    @wikii_push_pull_rotate = 0.0
    @wikii_push_pull_rotate_step = false
    @wikii_push_pull_scale = 1.0
    @wikii_push_pull_z = false

    def wi_average
      result = 0
      each { |value| result += value }
      result / length
    end

    def sort_edges(edges)
      return if edges.empty?

      result = []

      while edges.length != 0
        start = nil

        edges.each do |edge|
          start = edge.start
          break if (edge.start.edges & edges).length == 1

          start = edge.end
          break if (edge.end.edges & edges).length == 1
        end

        vertices = []
        curve = []

        while start
          next_edge = (start.edges & edges - curve)[0]

          if next_edge
            curve << next_edge
            vertices << start
            start = next_edge.other_vertex(start)
          else
            vertices << start
            start = nil
          end
        end

        edges -= curve
        result << [curve, vertices]
      end

      result
    end

    def wikii_push_pull
      @wikii_push_pull_recodes = []
      Sketchup.active_model.start_operation("wikii_push_pull")

      selection = Sketchup.active_model.selection
      faces = selection.grep(Sketchup::Face)
      return if faces.empty?

			edges = selection.grep(Sketchup::Edge)
			edges = edges - faces.flat_map { |face| face.edges }.flatten
			edges = sort_edges(edges)
			return if edges.nil? || edges.empty?
			edges = edges.sort { |x, y| x[0].length <=> y[0].length }
			path_entry = edges[-1]

			construction_points = selection.grep(Sketchup::ConstructionPoint)

			path_vertex_refs = path_entry[1]
			curve_vertices = path_vertex_refs.map { |vertex| vertex.position }
			path_start = curve_vertices[0]
			path_end = curve_vertices[-1]
			closed_path = path_start == path_end

      @wikii_push_pull_rotate_step = true
      @wikii_push_pull_rotate = 0
      @wikii_push_pull_scale = 1
      @wikii_push_pull_z = true

      wikii_push_pull_step_rotate = @wikii_push_pull_rotate / (@wikii_push_pull_rotate_step ? 1 : curve_vertices.length - 1)

      faces.each do |face|
      	path_vertex_refs = path_entry[1]
        curve_vertices = path_vertex_refs.map { |vertex| vertex.position }

        # determine path/profile anchor point
        face_center = nil

        if !construction_points.empty?
          face_center = construction_points[0].position
        else
          case true
						when closed_path
							path_vertex_refs.each { |vertex| face_center = vertex.position if vertex.faces.include?(face) }
							face_center = face.wi_center unless face_center
						when path_vertex_refs[0].faces.include?(face)
							face_center = path_vertex_refs[0].position
						when path_vertex_refs[-1].faces.include?(face)
							face_center = path_vertex_refs[-1].position
						else
							face_center = face.wi_center
						end
        end

        # determine path start point
        if closed_path
          n = -1
          curve_vertices = curve_vertices[0..-2]
          min = curve_vertices.map { |point| n += 1; [point.distance(face_center), n] }.sort { |x, y| x[0] <=> y[0] }[0][1]
#          p min
          curve_vertices = curve_vertices[min..-1] + curve_vertices[0..min]
          curve_vertices.uniq!
          curve_vertices << curve_vertices[0]
        else
          curve_vertices.reverse! if path_start.distance(face_center) > path_end.distance(face_center)
        end

        translation = face_center - curve_vertices[0]
        curve_vertices.map! { |point| point + translation }

face_vertices = face.vertices.map { |vertex| vertex.position }

# align profile to path
v1 = curve_vertices[1] - curve_vertices[0]
face_normal = face.normal
v2 = face_normal

if face_normal.angle_between(v1) > Math::PI / 2
  face.reverse!
  v2 = face.normal
end

v1.z = 0
v2.z = 0
next if v2.length == 0

v3 = v2 * v1

if v3.length != 0
  t = Geom::Transformation.rotation(face_center, v3, v1.angle_between(v2))
  face_vertices.map! { |point| point.transform(t) }
  v2 = face.normal.transform(t)
  v3 = v2 * v1

  if v3.length != 0
    t = Geom::Transformation.rotation(face_center, v3, v1.angle_between(v2))
    face_vertices.map! { |point| point.transform(t) }
  end
end

group_entities = Sketchup.active_model.active_entities.add_group.entities
temp_vertices = []

if closed_path
  v1 = curve_vertices[-2]
  v2 = curve_vertices[0]
  v3 = curve_vertices[1]

  vca = (v1 - v2)
  vcb = (v3 - v2)

  vca.z = 0 if @wikii_push_pull_z
  vcb.z = 0 if @wikii_push_pull_z
  vca.length = vcb.length = 1

  if (vca * vcb).length == 0
    normal = vca
  else
    vc1 = Geom::Vector3d.linear_combination(1, vca, 1, vcb)
    vc2 = vca * vcb
    normal = vc1 * vc2
    normal = vc1 if normal.length == 0
  end

  plane = [curve_vertices[0], normal]

  face_vertices.each do |point|
    st1 = Geom.intersect_line_plane([point, curve_vertices[1] - curve_vertices[0]], plane)
    temp_vertices << st1
  end
else
  face_vertices.each do |point|
    temp_vertices << point
  end
end

new_face = group_entities.add_face(temp_vertices)
group_entities.add_cpoint(face_center)

@fvs = face_vertices = temp_vertices
edges_not_smooth = []
edges_not_smooth_last = []

curve_vertices_length = curve_vertices.length

curve_vertices.each_index do |index|
  v1 = curve_vertices[index]
  v2 = nil
  v3 = nil

  case true
  when index == curve_vertices_length - 1
    next
  when index == curve_vertices_length - 2

    if closed_path
      v2 = curve_vertices[index + 1]
      v3 = curve_vertices[1]

      face_vertices.each_index do |ii|
        edges_not_smooth << (y = group_entities.add_line(face_vertices[ii], @fvs[ii]))
        y.find_faces
        y = group_entities.add_line(face_vertices[ii], @fvs[(ii + 1) - @fvs.length])
        y.find_faces
      end

      break
    else
      v2 = curve_vertices[index + 1]
      vect = v2 - v1
      vect.z = 0 if @wikii_push_pull_z
      v3 = v2 + vect
    end
  else
    v2 = curve_vertices[index + 1]
    v3 = curve_vertices[index + 2]
  end

  vca = (v1 - v2)
  vcb = (v3 - v2)

  vca.z = 0 if @wikii_push_pull_z
  vcb.z = 0 if @wikii_push_pull_z

  if vca.length != 0
    vca.length = 1
  end

  if vcb.length != 0
    vcb.length = 1
  end

		cross = vca * vcb
		if cross.length == 0
		normal = vca
		normal.z = 0 if @wikii_push_pull_z
		plane = [v2, normal]
		else
		vx = cross
		vx = Geom::Vector3d.new(0, 0, 1) if @wikii_push_pull_z
		va = vca + vcb
		normal = va * vx
    normal.z = 0 if @wikii_push_pull_z
    plane = [v2, normal]
  end

  segment_vector = v2 - v1

  face_vertices = face_vertices.map do |vertex_or_point|
    vertex_or_point = vertex_or_point.position if vertex_or_point.class == Sketchup::Vertex
    p_normal = segment_vector.clone
    p_normal.z = 0 if @wikii_push_pull_z
    y = Geom.intersect_line_plane([vertex_or_point, p_normal], plane)
    edges_not_smooth << group_entities.add_line(vertex_or_point, y)
    y # intersection_point
  end

  new_face_center = Geom.intersect_line_plane([face_center, segment_vector], plane)

  new_face.erase! if !new_face.deleted? and index != 0
  new_face = group_entities.add_face(face_vertices)
  edges_not_smooth_last = new_face.edges
  @wikii_push_pull_recodes << [group_entities, new_face.edges, new_face_center, normal]
  new_face.edges.each { |edge| edge.find_faces }

  if @wikii_push_pull_rotate != 0
    t = Geom::Transformation.rotation(new_face_center, normal, wikii_push_pull_step_rotate)
    group_entities.transform_entities(t, new_face)
  end

  if @wikii_push_pull_scale != 1
    t = Geom::Transformation.scaling(new_face_center, @wikii_push_pull_scale)
    group_entities.transform_entities(t, new_face)
  end

  if @wikii_push_pull_z
    t = Geom::Transformation.translation(Geom::Vector3d.new(0, 0, v2.z - v1.z))
    group_entities.transform_entities(t, new_face)
  end

  face_vertices = new_face.vertices
  face_center = new_face_center
end
        (group_entities.to_a - edges_not_smooth - edges_not_smooth_last).each do |entity|
          entity.smooth = entity.soft = true if entity.typename == "Edge"
        end

        new_face.erase! if closed_path
      end

      Sketchup.active_model.commit_operation
    end

   puts "version #{VERSION}"
  end
end
