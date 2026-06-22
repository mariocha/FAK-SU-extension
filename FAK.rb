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

module WikiiFAK

  class Face
    def center_position
      positions = vertices.map(&:position)
      return Geom::Point3d.new(0, 0, 0) if positions.empty?
      
      sum_x = sum_y = sum_z = 0
      positions.each do |pos|
        sum_x += pos.x
        sum_y += pos.y
        sum_z += pos.z
      end
      
      count = positions.length.to_f
      Geom::Point3d.new(sum_x / count, sum_y / count, sum_z / count)
    end
  end

  class Array
    def average
      return 0 if empty?
      sum(0) / length.to_f
    end
  end

  class FollowMeKeepZ
    def initialize
      @records = []
      @rotation = 0.0
      @rotation_step = false
      @scale = 1.0
      @preserve_z = false
    end

    def sort_edges(edges)
      return [] if edges.empty?
      
      result = []
      remaining_edges = edges.dup
      
      while remaining_edges.any?
        start_vertex = find_path_start(remaining_edges)
        vertices = []
        curve = []
        current = start_vertex

        while current
          next_edge = (current.edges & remaining_edges - curve).first
          if next_edge
            curve << next_edge
            vertices << current
            current = next_edge.other_vertex(current)
          else
            vertices << current
            current = nil
          end
        end

        remaining_edges -= curve
        result << [curve, vertices]
      end
      
      result
    end

    private

    def find_path_start(edges)
      edges.each do |edge|
        return edge.start if (edge.start.edges & edges).length == 1
        return edge.end if (edge.end.edges & edges).length == 1
      end
      edges.first.start
    end

    def get_selection_by_type(selection, type)
      case type
      when :faces
        selection.grep(Sketchup::Face)
      when :edges
        selection.grep(Sketchup::Edge)
      when :construction_points
        selection.grep(Sketchup::ConstructionPoint)
      else
        []
      end
    end

    def create_path_vertices(edges)
      return [] if edges.empty?
      edges[-1][1].map(&:position)
    end

    def is_closed_path?(path_vertices)
      return false if path_vertices.empty?
      path_vertices.first == path_vertices.last
    end

    def find_center_point(face, path_vertices, construction_points, closed_path)
      return construction_points.first.position if construction_points.any?

      case true
      when closed_path
        path_vertices.each { |v| return v if face.vertices.map(&:position).include?(v) }
        face.center_position
      when face.vertices.map(&:position).include?(path_vertices.first)
        path_vertices.first
      when face.vertices.map(&:position).include?(path_vertices.last)
        path_vertices.last
      else
        face.center_position
      end
    end

    def rotate_path_to_nearest_vertex(path_vertices, center_point, closed_path)
      return path_vertices unless closed_path

      vertices_without_duplicate = path_vertices[0..-2]
      distances_with_indices = vertices_without_duplicate.each_with_index.map do |v, idx|
        [v.distance(center_point), idx]
      end.sort_by { |d, _| d }

      nearest_index = distances_with_indices.first[1]
      rotated = vertices_without_duplicate[nearest_index..-1] + vertices_without_duplicate[0..nearest_index]
      rotated.uniq!
      rotated << rotated.first
      rotated
    end

    def reverse_path_if_needed(path_vertices, center_point)
      return path_vertices if path_vertices.length < 2
      
      if path_vertices.first.distance(center_point) > path_vertices.last.distance(center_point)
        path_vertices.reverse
      else
        path_vertices
      end
    end

    def translate_path_to_origin(path_vertices, center_point)
      translation_vector = center_point - path_vertices.first
      path_vertices.map { |v| v + translation_vector }
    end

    def auto_rotate_face_to_path(face, path_vertices)
      return unless path_vertices.length > 1

      path_direction = path_vertices[1] - path_vertices.first
      face_normal = face.normal.dup

      if face_normal.angle_between(path_direction) > (Math::PI / 2)
        face.reverse!
      end

      # Align face to path
      align_face_normal_to_path(face, path_direction, path_vertices.first)
    end

    def align_face_normal_to_path(face, path_direction, alignment_point)
      path_dir_horizontal = path_direction.dup
      path_dir_horizontal.z = 0
      
      face_normal_horizontal = face.normal.dup
      face_normal_horizontal.z = 0

      return if face_normal_horizontal.length == 0

      perpendicular = face_normal_horizontal * path_dir_horizontal
      return if perpendicular.length == 0

      angle = path_dir_horizontal.angle_between(face_normal_horizontal)
      transformation = Geom::Transformation.rotation(alignment_point, perpendicular, angle)

      face.vertices.each do |v|
        v.position = v.position.transform(transformation)
      end
    end

    def calculate_intersection_plane(vertices, path_segment_start, preserve_z)
      v_previous = vertices[-2]
      v_current = vertices[0]
      v_next = vertices[1]

      vector_a = (v_previous - v_current).dup
      vector_b = (v_next - v_current).dup

      vector_a.z = 0 if preserve_z
      vector_b.z = 0 if preserve_z

      vector_a.length = vector_b.length = 1

      cross_product = vector_a * vector_b
      
      if cross_product.length == 0
        normal = vector_a
        normal.z = 0 if preserve_z
      else
        combined = Geom::Vector3d.linear_combination(1, vector_a, 1, vector_b)
        cross = vector_a * vector_b
        normal = combined * cross
        normal = combined if normal.length == 0
      end

      [path_segment_start, normal]
    end

    def project_vertices_onto_plane(vertices, plane, preserve_z)
      vertices.map do |v|
        projection = Geom.intersect_line_plane([v, plane.last], plane)
        projection || v
      end
    end

    def create_face_at_path_segment(group, projected_vertices)
      group.add_face(projected_vertices)
    end

    def create_connecting_edges(group, original_vertices, projected_vertices, closed_path)
      edges = []
      
      original_vertices.each_with_index do |orig_v, idx|
        edges << group.add_line(orig_v, projected_vertices[idx])
        edges.last.find_faces
        
        next_idx = (idx + 1) % projected_vertices.length
        edges << group.add_line(orig_v, projected_vertices[next_idx])
        edges.last.find_faces
      end if closed_path

      edges
    end

    def apply_rotation(group, face, transformation_point, rotation_amount)
      return if rotation_amount == 0
      
      normal = face.normal
      transformation = Geom::Transformation.rotation(transformation_point, normal, rotation_amount)
      group.transform_entities(transformation, face)
    end

    def apply_scale(group, face, transformation_point, scale_amount)
      return if scale_amount == 1
      
      transformation = Geom::Transformation.scaling(transformation_point, scale_amount)
      group.transform_entities(transformation, face)
    end

    def apply_z_translation(group, face, z_offset)
      return if z_offset == 0
      
      translation = Geom::Transformation.translation(Geom::Vector3d.new(0, 0, z_offset))
      group.transform_entities(translation, face)
    end

    def smooth_edges(edges, non_smooth_edges)
      (edges - non_smooth_edges).each do |edge|
        edge.smooth = edge.soft = true if edge.typename == "Edge"
      end
    end

    public

    def wikii_push_pull
      @records = []
      
      model = Sketchup.active_model
      selection = model.selection
      
      model.start_operation("wikii_push_pull")

      faces = get_selection_by_type(selection, :faces)
      return if faces.empty?

      all_edges = get_selection_by_type(selection, :edges)
      face_edges = faces.flat_map(&:edges).uniq
      edges_to_process = all_edges - face_edges
      edges_to_process = sort_edges(edges_to_process).sort_by { |e| e.first.length }

      construction_points = get_selection_by_type(selection, :construction_points)

      path_vertices = create_path_vertices(edges_to_process)
      closed_path = is_closed_path?(path_vertices)

      @rotation_step = true
      @rotation = 0
      @scale = 1
      @preserve_z = true

      rotation_step_amount = @rotation / (@rotation_step ? 1 : path_vertices.length - 1)

      faces.each do |face|
        path_vertices = create_path_vertices(edges_to_process)
        
        center_point = find_center_point(face, path_vertices, construction_points, closed_path)
        path_vertices = rotate_path_to_nearest_vertex(path_vertices, center_point, closed_path)
        path_vertices = reverse_path_if_needed(path_vertices, center_point)
        path_vertices = translate_path_to_origin(path_vertices, center_point)

        face_vertices = face.vertices.map(&:position)
        
        auto_rotate_face_to_path(face, path_vertices)

        group = model.active_entities.add_group
        group_entities = group.entities
        
        if closed_path
          plane = calculate_intersection_plane(path_vertices, path_vertices.first, @preserve_z)
          projected_vertices = project_vertices_onto_plane(face_vertices, plane, @preserve_z)
        else
          projected_vertices = face_vertices
        end

        new_face = create_face_at_path_segment(group_entities, projected_vertices)
        group_entities.add_cpoint(center_point)
        
        face_vertices = projected_vertices
        non_smooth_edges = []
        non_smooth_edges_last = []

        path_vertices.each_with_index do |current_vertex, idx|
          next if idx == path_vertices.length - 1

          if idx == path_vertices.length - 2
            if closed_path
              next_vertex = path_vertices[idx + 1]
              next_next_vertex = path_vertices[1]
              
              face_vertices.each_index do |vi|
                edge = group_entities.add_line(face_vertices[vi], projected_vertices[vi])
                non_smooth_edges << edge
                edge.find_faces
                
                edge = group_entities.add_line(face_vertices[vi], projected_vertices[(vi + 1) % projected_vertices.length])
                edge.find_faces
              end
              break
            else
              next_vertex = path_vertices[idx + 1]
              direction = next_vertex - current_vertex
              direction.z = 0 if @preserve_z
              next_next_vertex = next_vertex + direction
            end
          else
            next_vertex = path_vertices[idx + 1]
            next_next_vertex = path_vertices[idx + 2]
          end

          plane = calculate_intersection_plane([current_vertex, next_vertex, next_next_vertex], next_vertex, @preserve_z)
          face_vertices = project_vertices_onto_plane(face_vertices, plane, @preserve_z)

          new_face.erase! if !new_face.deleted? && idx != 0
          new_face = create_face_at_path_segment(group_entities, face_vertices)
          non_smooth_edges_last = new_face.edges
          
          @records << [group, new_face.edges, next_vertex, plane.last]

          new_face.edges.each(&:find_faces)

          apply_rotation(group, new_face, next_vertex, rotation_step_amount) if @rotation != 0
          apply_scale(group, new_face, next_vertex, @scale) if @scale != 1
          apply_z_translation(group, new_face, next_vertex.z - current_vertex.z) if @preserve_z
        end

        smooth_edges(group_entities.to_a, non_smooth_edges + non_smooth_edges_last)
        new_face.erase! if closed_path
      end

      model.commit_operation
    end
  end

  if !(defined? Sutool)
    if !file_loaded?("FAK.rb")
      add_separator_to_menu("Plugins")
      UI.menu("Plugins").add_item(FakLH['FollowMeAndKeep']) do
        FollowMeKeepZ.new.wikii_push_pull
      end
    end
    file_loaded("FAK.rb")
  end
end
