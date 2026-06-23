# encoding: utf-8
=begin
##Author : f3d, based on Wikii's work
##Date    :2026.06
##Ver     :1.0

v 1.0 Modernized and optimized
=end

module F3DFAK
  VERSION = 'dev220'

	class Face
		def wi_center
			sx = sy = sz = 0.0
			verts = vertices
			verts.each do |vertex|
				point = vertex.position
				sx += point.x
				sy += point.y
				sz += point.z
			end
			count = verts.length
			Geom::Point3d.new(sx / count, sy / count, sz / count)
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
		end #sort_edges

		def wikii_push_pull
			@wikii_push_pull_recodes = []
			model = Sketchup.active_model
			model.start_operation("wikii_push_pull")

			selection = model.selection
			faces = selection.grep(Sketchup::Face)
			if faces.empty?
				model.abort_operation
				return
			end

			edges = selection.grep(Sketchup::Edge)
			edges = edges - faces.flat_map { |face| face.edges }.flatten
			edges = sort_edges(edges)
			if edges.nil? || edges.empty?
				model.abort_operation
				return
			end

			path_entry = edges.max_by { |entry| entry[0].length }

			construction_points = selection.grep(Sketchup::ConstructionPoint)

			path_vertex_refs = path_entry[1]
			base_curve_vertices = path_vertex_refs.map { |vertex| vertex.position }
			path_start = base_curve_vertices[0]
			path_end = base_curve_vertices[-1]

			if path_start == path_end
				UI.messagebox("Closed paths are not supported in this version.")
				model.abort_operation
				return
			end

			@wikii_push_pull_rotate_step = true
			@wikii_push_pull_rotate = 0
			@wikii_push_pull_scale = 1
			@wikii_push_pull_z = true

			wikii_push_pull_step_rotate = @wikii_push_pull_rotate / (@wikii_push_pull_rotate_step ? 1 : curve_vertices.length - 1)

			path_first_vertex = path_vertex_refs[0]
			path_last_vertex = path_vertex_refs[-1]
			faces.each do |face|
			curve_vertices = base_curve_vertices.dup

			face_center =
				if !construction_points.empty?
					construction_points[0].position
					elsif path_first_vertex.faces.include?(face)
						face_center = path_first_vertex.position
					elsif path_last_vertex.faces.include?(face)
						face_center = path_last_vertex.position
				else
					face.wi_center
				end

				curve_vertices.reverse! if path_start.distance(face_center) > path_end.distance(face_center)

				translation = face_center - curve_vertices[0]
				curve_vertices.map! { |point| point + translation }

				face_vertices = face.vertices.map { |vertex| vertex.position }

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

				group_entities = model.active_entities.add_group.entities
				temp_vertices = face_vertices.dup

				new_face = group_entities.add_face(temp_vertices)
				group_entities.add_cpoint(face_center)

				@fvs = face_vertices = temp_vertices
				edges_not_smooth = []
				edges_not_smooth_last = []

				curve_vertices_length = curve_vertices.length
				last_curve_index = curve_vertices_length - 1
				second_last_curve_index = curve_vertices_length - 2

				curve_vertices.each_index do |index|
					v1 = curve_vertices[index]
					v2 = nil
					v3 = nil

					case true
					when index == last_curve_index
						next
					when index == second_last_curve_index

					v2 = curve_vertices[index + 1]
					segment_vector = v2 - v1
					segment_vector.z = 0 if @wikii_push_pull_z
					v3 = v2 + segment_vector
				else
					v2 = curve_vertices[index + 1]
					v3 = curve_vertices[index + 2]
				end

				vca = v1 - v2
				vcb = v3 - v2

				vca.z = 0 if @wikii_push_pull_z
				vcb.z = 0 if @wikii_push_pull_z

				vca.length = 1 if vca.length != 0
				vcb.length = 1 if vcb.length != 0

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
				projection_vector = segment_vector.clone
				projection_vector.z = 0 if @wikii_push_pull_z

				face_vertices = face_vertices.map do |vertex_or_point|
				vertex_or_point = vertex_or_point.position if vertex_or_point.is_a?(Sketchup::Vertex)
				y = Geom.intersect_line_plane([vertex_or_point, projection_vector], plane)
				new_edge = group_entities.add_line(vertex_or_point, y)
				new_edge.find_faces
				edges_not_smooth << new_edge
				y
			end

				new_face_center = Geom.intersect_line_plane([face_center, segment_vector], plane)

				new_face.erase! if !new_face.deleted? && index != 0
				new_face = group_entities.add_face(face_vertices)
				new_face_edges = new_face.edges
				edges_not_smooth_last = new_face_edges
				@wikii_push_pull_recodes << [group_entities, new_face_edges, new_face_center, normal]
				new_face_edges.each { |edge| edge.find_faces }

				if @wikii_push_pull_rotate != 0
					t = Geom::Transformation.rotation(new_face_center, normal, wikii_push_pull_step_rotate)
					group_entities.transform_entities(t, new_face)
				end

				if @wikii_push_pull_scale != 1
					t = Geom::Transformation.scaling(new_face_center, @wikii_push_pull_scale)
					group_entities.transform_entities(t, new_face)
				end

				if @wikii_push_pull_z
					z_offset = v2.z - v1.z
					t = Geom::Transformation.translation(Geom::Vector3d.new(0, 0, z_offset))
					group_entities.transform_entities(t, new_face)
				end

				face_vertices = new_face.vertices
				face_center = new_face_center
			end

			group_entities_items = group_entities.to_a

			skip = {}
			edges_not_smooth.each { |edge| skip[edge] = true }
			edges_not_smooth_last.each { |edge| skip[edge] = true }

			group_entities_items.each do |entity|
				next if skip[entity]
				entity.smooth = entity.soft = true if entity.typename == "Edge"
			end
		end

		model.commit_operation
	 end
	 puts "dev version #{VERSION}"
	 end
end
