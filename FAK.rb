# encoding: utf-8
=begin
##Author : f3d, based on Wikii's work
##Date    :2026.06
##Ver     :1.0

v 1.0 Modernized and optimized
=end

module F3DFAK
  VERSION = 'dev292+in'

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

  class Builder
    attr_reader :records

    def initialize(model:, rotate: 0.0, rotate_step: false, scale: 1.0, push_pull_z: false)
      @model = model
      @rotate = rotate
      @rotate_step = rotate_step
      @scale = scale
      @push_pull_z = push_pull_z
      @records = []
    end

    def build(face:, path_vertices:, path_edges:)
      group = model.active_entities.add_group
      group_entities = group.entities

      base_path_points = path_points_from_refs(path_vertices)
      path_start = base_path_points[0]
      path_end = base_path_points[-1]

      if path_start == path_end
        UI.messagebox("Closed paths are not supported in this version.")
        group.erase! unless group.deleted?
        return nil
      end

      rotate_step_value = rotate_step_amount(base_path_points.length)
      path_first_vertex = path_vertices[0]
      path_last_vertex = path_vertices[-1]

      path_points = base_path_points.dup
      face_center = determine_face_center(
        face: face,
        path_first_vertex: path_first_vertex,
        path_last_vertex: path_last_vertex
      )

      path_points.reverse! if path_start.distance(face_center) > path_end.distance(face_center)

      translation = face_center - path_points[0]
      path_points.map! { |point| point + translation }

      face_vertices = face.vertices.map { |vertex| vertex.position }
      face_vertices = align_face_vertices(face, face_center, face_vertices, path_points)

      new_face = group_entities.add_face(face_vertices)
      group_entities.add_cpoint(face_center)

      edges_not_smooth = []
      edges_not_smooth_last = []

      path_points_length = path_points.length
      last_curve_index = path_points_length - 1
      second_last_curve_index = path_points_length - 2

      path_points.each_index do |index|
        v1 = path_points[index]
        v2 = nil
        v3 = nil

        case true
        when index == last_curve_index
          next
        when index == second_last_curve_index
          v2 = path_points[index + 1]
          segment_vector = v2 - v1
          segment_vector.z = 0 if push_pull_z
          v3 = v2 + segment_vector
        else
          v2 = path_points[index + 1]
          v3 = path_points[index + 2]
        end

        normal, plane = build_plane(v1, v2, v3)
        segment_vector = v2 - v1
        projection = projection_vector(segment_vector)

        face_vertices = face_vertices.map do |vertex_or_point|
          project_face_vertex(
            vertex_or_point,
            plane,
            projection,
            group_entities,
            edges_not_smooth
          )
        end

        new_face_center = Geom.intersect_line_plane([face_center, segment_vector], plane)

        new_face.erase! if !new_face.deleted? && index != 0
        new_face = group_entities.add_face(face_vertices)
        new_face_edges = new_face.edges
        edges_not_smooth_last = new_face_edges
        records << [group_entities, new_face_edges, new_face_center, normal]
        new_face_edges.each { |edge| edge.find_faces }

        apply_face_transforms(
          group_entities: group_entities,
          new_face: new_face,
          new_face_center: new_face_center,
          normal: normal,
          rotate_step_value: rotate_step_value,
          v1: v1,
          v2: v2
        )

        face_vertices = new_face.vertices
        face_center = new_face_center
      end

      smooth_remaining_edges(group_entities, edges_not_smooth, edges_not_smooth_last)

      write_attributes(
        group,
        face: face,
        path_vertices: path_vertices,
        path_edges: path_edges
      )

      group
    end #build

    private

    attr_reader :model, :rotate, :rotate_step, :scale, :push_pull_z

    def write_attributes(group, face:, path_vertices:, path_edges:)
      group.set_attribute('F3DFAK', 'version', VERSION)
      group.set_attribute('F3DFAK', 'rotate', rotate)
      group.set_attribute('F3DFAK', 'rotate_step', rotate_step)
      group.set_attribute('F3DFAK', 'scale', scale)
      group.set_attribute('F3DFAK', 'push_pull_z', push_pull_z)
      group.set_attribute('F3DFAK', 'path_vertex_count', path_vertices.length)
      group.set_attribute('F3DFAK', 'path_edge_count', path_edges.length)

      if face.respond_to?(:persistent_id)
        group.set_attribute('F3DFAK', 'source_face_persistent_id', face.persistent_id)
      end

      if path_vertices.all? { |vertex| vertex.respond_to?(:persistent_id) }
        vertex_ids = path_vertices.map(&:persistent_id)
        group.set_attribute('F3DFAK', 'path_vertex_persistent_ids', vertex_ids.join(','))
      end

      if path_edges.all? { |edge| edge.respond_to?(:persistent_id) }
        edge_ids = path_edges.map(&:persistent_id)
        group.set_attribute('F3DFAK', 'path_edge_persistent_ids', edge_ids.join(','))
      end
    end #write_attributes

    def path_points_from_refs(path_vertices)
      path_vertices.map { |vertex| vertex.position }
    end

    def rotate_step_amount(curve_length)
      rotate / (rotate_step ? 1 : curve_length - 1)
    end

    def determine_face_center(face:, path_first_vertex:, path_last_vertex:)
      if path_first_vertex.faces.include?(face)
        path_first_vertex.position
      elsif path_last_vertex.faces.include?(face)
        path_last_vertex.position
      else
        face.wi_center
      end
    end

    def align_face_vertices(face, face_center, face_vertices, path_points)
      v1 = path_points[1] - path_points[0]
      face_normal = face.normal
      v2 = face_normal

      if face_normal.angle_between(v1) > Math::PI / 2
        face.reverse!
        v2 = face.normal
      end

      v1.z = 0
      v2.z = 0
      return face_vertices if v2.length == 0

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

      face_vertices
    end

    def build_plane(v1, v2, v3)
      vca = v1 - v2
      vcb = v3 - v2

      vca.z = 0 if push_pull_z
      vcb.z = 0 if push_pull_z

      vca.length = 1 if vca.length != 0
      vcb.length = 1 if vcb.length != 0

      cross = vca * vcb

      if cross.length == 0
        normal = vca
        normal.z = 0 if push_pull_z
        plane = [v2, normal]
      else
        vx = cross
        vx = Geom::Vector3d.new(0, 0, 1) if push_pull_z
        va = vca + vcb
        normal = va * vx
        normal.z = 0 if push_pull_z
        plane = [v2, normal]
      end

      [normal, plane]
    end

    def projection_vector(segment_vector)
      vector = segment_vector.clone
      vector.z = 0 if push_pull_z
      vector
    end

    def project_face_vertex(vertex_or_point, plane, projection, group_entities, edges_not_smooth)
      point = vertex_position(vertex_or_point)
      projected = Geom.intersect_line_plane([point, projection], plane)
      new_edge = group_entities.add_line(point, projected)
      new_edge.find_faces
      edges_not_smooth << new_edge
      projected
    end

    def vertex_position(vertex_or_point)
      vertex_or_point.is_a?(Sketchup::Vertex) ? vertex_or_point.position : vertex_or_point
    end

    def apply_face_transforms(group_entities:, new_face:, new_face_center:, normal:, rotate_step_value:, v1:, v2:)
      if rotate != 0
        t = Geom::Transformation.rotation(new_face_center, normal, rotate_step_value)
        group_entities.transform_entities(t, new_face)
      end

      if scale != 1
        t = Geom::Transformation.scaling(new_face_center, scale)
        group_entities.transform_entities(t, new_face)
      end

      if push_pull_z
        z_offset = v2.z - v1.z
        t = Geom::Transformation.translation(Geom::Vector3d.new(0, 0, z_offset))
        group_entities.transform_entities(t, new_face)
      end
    end

    def smooth_remaining_edges(group_entities, edges_not_smooth, edges_not_smooth_last)
      group_entities_items = group_entities.to_a

      skip = {}
      edges_not_smooth.each { |edge| skip[edge] = true }
      edges_not_smooth_last.each { |edge| skip[edge] = true }

      group_entities_items.each do |entity|
        next if skip[entity]
        entity.smooth = entity.soft = true if entity.typename == "Edge"
      end
    end
  end

  class Follow_me_keep_z
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
      path_edges = path_entry[0]
      path_vertices = path_entry[1]

      rotate_step = true
      rotate = 0
      scale = 1
      push_pull_z = true

      builder = Builder.new(
        model: model,
        rotate: rotate,
        rotate_step: rotate_step,
        scale: scale,
        push_pull_z: push_pull_z
      )

      faces.each do |face|
        group = builder.build(
          face: face,
          path_vertices: path_vertices,
          path_edges: path_edges
        )

        if group.nil?
          model.abort_operation
          return
        end

#        p self.send(:resolve_procedural_references, group, model)
        # p self.send(:procedural_reference_status, group, model)
        # p(
        #   version: self.send(:stored_version, group),
        #   parameters: self.send(:stored_parameters, group),
        #   reference_status: self.send(:procedural_reference_status, group, model)
        # )
      end

      puts "dev version #{VERSION}"
      model.commit_operation
    end #wikii_push_pull

    private

def procedural_group_rebuildable?(group, model)
  refs = resolve_procedural_references(group, model)

  !refs[:face].nil? &&
    refs[:vertices].none?(&:nil?) &&
    refs[:edges].none?(&:nil?)
end

    def resolve_procedural_references(group, model)
      face_id = stored_source_face_id(group)
      vertex_ids = stored_path_vertex_ids(group)
      edge_ids = stored_path_edge_ids(group)

      face = face_id.nil? ? nil : model.find_entity_by_persistent_id(face_id)
      vertices = vertex_ids.map { |id| model.find_entity_by_persistent_id(id) }
      edges = edge_ids.map { |id| model.find_entity_by_persistent_id(id) }

      {
        face: face,
        vertices: vertices,
        edges: edges
      }
    end

    def procedural_dictionary
      'F3DFAK'
    end

    def procedural_group?(entity)
      return false unless entity.is_a?(Sketchup::Group)
      !entity.get_attribute(procedural_dictionary, 'version').nil?
    end

    def stored_version(group)
      group.get_attribute(procedural_dictionary, 'version')
    end

    def stored_source_face_id(group)
      group.get_attribute(procedural_dictionary, 'source_face_persistent_id')
    end

    def stored_path_vertex_ids(group)
      value = group.get_attribute(procedural_dictionary, 'path_vertex_persistent_ids')
      value.to_s.split(',').reject(&:empty?).map(&:to_i)
    end

    def stored_path_edge_ids(group)
      value = group.get_attribute(procedural_dictionary, 'path_edge_persistent_ids')
      value.to_s.split(',').reject(&:empty?).map(&:to_i)
    end

    def stored_parameters(group)
      {
        rotate: group.get_attribute(procedural_dictionary, 'rotate'),
        rotate_step: group.get_attribute(procedural_dictionary, 'rotate_step'),
        scale: group.get_attribute(procedural_dictionary, 'scale'),
        push_pull_z: group.get_attribute(procedural_dictionary, 'push_pull_z')
      }
    end

    def procedural_reference_status(group, model)
      face_id = stored_source_face_id(group)
      vertex_ids = stored_path_vertex_ids(group)
      edge_ids = stored_path_edge_ids(group)

      {
        face_exists: !face_id.nil? && !model.find_entity_by_persistent_id(face_id).nil?,
        vertex_count: vertex_ids.length,
        edge_count: edge_ids.length,
        vertices_exist: vertex_ids.all? { |id| !model.find_entity_by_persistent_id(id).nil? },
        edges_exist: edge_ids.all? { |id| !model.find_entity_by_persistent_id(id).nil? }
      }
    end

    puts "dev version #{VERSION}"
  end
end
