require 'nokogiri'

require 'caracal/renderers/xml_renderer'
require 'caracal/errors'


module Caracal
  module Renderers
    class DocumentRenderer < XmlRenderer
      #-------------------------------------------------------------
      # Public Methods
      #-------------------------------------------------------------

      # This method produces the xml required for the `word/document.xml`
      # sub-document.
      #
      def to_xml
        builder = ::Nokogiri::XML::Builder.with(declaration_xml) do |xml|
          xml['w'].document root_options do
            xml['w'].background 'w:color' => 'FFFFFF'
            xml['w'].body do
              #============= CONTENTS ===================================

              document.contents.each do |model|
                method = render_method_for_model(model)
                send(method, xml, model)
              end

              #============= PAGE SETTINGS ==============================

              xml['w'].sectPr do
                document.relationships_by_type(:header).each do |rel|
                  header = rel.owner
                  xml['w'].headerReference 'r:id' => rel.formatted_id, 'w:type' => (header.header_type || 'default')
                end

                if document.page_number_show
                  if (rel = document.find_relationship('footer1.xml'))
                    xml['w'].footerReference 'r:id' => rel.formatted_id, 'w:type' => 'default'
                  end
                end
                xml['w'].pgSz page_size_options
                xml['w'].pgMar page_margin_options
              end

            end
          end
        end
        builder.to_xml save_options
      end


      #-------------------------------------------------------------
      # Private Methods
      #-------------------------------------------------------------
      private

      #============= COMMON RENDERERS ==========================

      # This method converts a model class name to a rendering
      # function on this class (e.g., Caracal::Core::Models::ParagraphModel
      # translates to `render_paragraph`).
      #
      def render_method_for_model(model)
        type = model.class.name.split('::').last.downcase.gsub('model', '')
        "render_#{ type }"
      end

      # This method renders a standard node of run properties based on the
      # model's attributes.
      #
      def render_run_attributes(xml, model, paragraph_level=false)
        if model.respond_to? :run_attributes
          attrs = model.run_attributes.delete_if { |k, v| v.nil? }

          if paragraph_level && attrs.empty?
            # skip
          else
            xml['w'].rPr do
              unless attrs.empty?
                xml['w'].rStyle    'w:val'  => attrs[:style]                           unless attrs[:style].nil?
                xml['w'].color     'w:val'  => attrs[:color]                           unless attrs[:color].nil?
                xml['w'].sz        'w:val'  => attrs[:size]                            unless attrs[:size].nil?
                xml['w'].b         'w:val'  => (attrs[:bold] ? '1' : '0')              unless attrs[:bold].nil?
                xml['w'].i         'w:val'  => (attrs[:italic] ? '1' : '0')            unless attrs[:italic].nil?
                xml['w'].u         'w:val'  => (attrs[:underline] ? 'single' : 'none') unless attrs[:underline].nil?
                xml['w'].shd       'w:val'  => 'clear', 'w:fill' => attrs[:bgcolor]    unless attrs[:bgcolor].nil?
                xml['w'].highlight 'w:val'  => attrs[:highlight_color]                 unless attrs[:highlight_color].nil?
                xml['w'].vertAlign 'w:val'  => attrs[:vertical_align]                  unless attrs[:vertical_align].nil?
                unless attrs[:font].nil?
                  f = attrs[:font]
                  xml['w'].rFonts 'w:ascii' => f, 'w:hAnsi' => f, 'w:eastAsia' => f, 'w:cs' => f
                end
              end
              xml['w'].rtl 'w:val' => '0'
            end
          end
        end
      end


      #============= MODEL RENDERERS ===========================

      def render_rawxml(xml, model)
        xml << model.to_s
      end

      def render_bookmark(xml, model)
        if model.start?
          xml['w'].bookmarkStart 'w:id' => model.bookmark_id, 'w:name' => model.bookmark_name
        else
          xml['w'].bookmarkEnd 'w:id' => model.bookmark_id
        end
      end

      def render_iframe(xml, model)
        ::Zip::File.open(model.file) do |zip|
          entry    = zip.glob('word/document.xml').first
          content  = entry.get_input_stream.read
          doc_xml  = Nokogiri::XML(content)
          ns       = document.namespaces
          fragment = doc_xml.xpath('//w:body').first.children

          fragment.pop

          model.relationships.each do |r_hash|
            id    = r_hash.delete(:id)              # we can't update the fragment until
            model = document.relationship(r_hash)   # the parent document assigns the embedded
            index = model.relationship_id           # relationship an id.

            r_node  = fragment.at_xpath("//a:blip[@r:embed='#{ id }']", { a: ns.t('a'), r: ns.t('r') })
            if (r_attr = r_node.attributes['embed'])
              r_attr.value = "rId#{ index }"
            end

            p_parent = r_node.parent.parent
            p_node   = p_parent.children[0].children[0]
            if (p_attr = p_node.attributes['id'])
              p_attr.value = index.to_s
            end
          end

          xml << fragment.to_s
        end
      end

      def render_image_proper(xml, model)
        rel      = document.relationship({ type: :image, target: model.image_url, data: model.image_data })
        rel_id   = rel.relationship_id
        rel_name = rel.formatted_target

        xml['wp'].extent cx: model.formatted_width, cy: model.formatted_height
        xml['wp'].effectExtent t: 0, b: 0, r: 0, l: 0
        xml['wp'].wrapTopAndBottom if model.image_anchor

        xml['wp'].docPr id: rel_id, name: rel_name

        xml['wp'].cNvGraphicFramePr do
          xml['a'].graphicFrameLocks noChangeAspect: '1'
        end

        ns = document.namespaces

        xml['a'].graphic do
          xml['a'].graphicData uri: ns.t('pic') do
            xml['pic'].pic do
              xml['pic'].nvPicPr do
                xml['pic'].cNvPr id: rel_id, name: rel_name
                xml['pic'].cNvPicPr
              end
              xml['pic'].blipFill do
                xml['a'].blip 'r:embed' => rel.formatted_id
                xml['a'].srcRect
                xml['a'].stretch do
                  xml['a'].fillRect
                end
              end
              xml['pic'].spPr do
                xml['a'].xfrm do
                  xml['a'].ext cx: model.formatted_width, cy: model.formatted_height
                end
                xml['a'].prstGeom prst: 'rect'
                xml['a'].ln
              end
            end
          end
        end
      end

      def render_image(xml, model)
        unless ds = document.default_style
          raise Caracal::Errors::NoDefaultStyleError 'Document must declare a default paragraph style.'
        end

        xml['w'].p paragraph_options do
          xml['w'].pPr do
            xml['w'].spacing 'w:lineRule' => 'auto', 'w:line' => ds.style_line
            xml['w'].contextualSpacing 'w:val' => '0'
            xml['w'].jc 'w:val' => model.image_align.to_s
            xml['w'].rPr
          end

          xml['w'].r run_options do
            xml['w'].drawing do
              dist = {distR: model.formatted_right, distT: model.formatted_top, distB: model.formatted_bottom, distL: model.formatted_left}

              if model.image_anchor
                xml['wp'].anchor dist.merge(relativeHeight: '0', simplePos: '0', locked: '1', layoutInCell: '0', allowOverlap: '0', behindDoc: '0') do
                  xml['wp'].simplePos x: 0, y: 0
                  xml['wp'].positionH relativeFrom: 'page' do # TODO: allow other relativeFrom values
                    xml['wp'].align model.image_align
                  end
                  xml['wp'].positionV relativeFrom: 'page' do # TODO: allow other relativeFrom values
                    xml['wp'].align 'top'
                  end

                  render_image_proper xml, model
                end
              else
                xml['wp'].inline dist do
                  render_image_proper xml, model
                end
              end
            end
          end

          xml['w'].r run_options do
            xml['w'].rPr do
              xml['w'].rtl 'w:val' => '0'
            end
          end
        end
      end

      def render_linebreak(xml, model)
        xml['w'].r do
          xml['w'].br
        end
      end

      def render_tableofcontent(xml, model)
        xml['w'].p paragraph_options do
          xml['w'].r do
            xml['w'].fldChar 'w:fldCharType' => 'begin'
          end
          xml['w'].r do
            xml['w'].instrText(
              { 'xml:space' => 'preserve' },
              " TOC \\o \"#{model.toc_start_level}-#{model.toc_end_level}\" \\h \\z \\u"
            )
          end
          xml['w'].r do
            xml['w'].fldChar 'w:fldCharType' => 'separate'
          end
        end

        bookmarks_for(headings).each do |bookmark|
          next unless model.includes? bookmark[:level] # Skip levels outside the accepted range

          xml['w'].p paragraph_options do
            xml['w'].pStyle 'w:val' => "TOC#{ bookmark[:level] }"
            xml['w'].tabs do
              xml['w'].tab 'w:val' => 'right', 'w:leader' => 'dot'
            end
            xml['w'].hyperlink 'w:anchor' => bookmark[:ref], 'w:history' => '1' do
              xml['w'].r do
                xml['w'].pPr do
                  xml['w'].rStyle 'w:val' => 'Hyperlink'
                end
                xml['w'].t bookmark[:text]
              end
              xml['w'].r do
                xml['w'].tab
              end
              xml['w'].r do
                xml['w'].fldChar 'w:fldCharType' => 'begin'
              end
              xml['w'].r do
                xml['w'].instrText(
                  { 'xml:space' => 'preserve' },
                  "  PAGEREF #{ bookmark[:ref] } \\h "
                )
              end
              xml['w'].r do
                xml['w'].fldChar 'w:fldCharType' => 'separate'
              end
              # Insert page reference here if it can be calculated
              xml['w'].r do
                xml['w'].fldChar 'w:fldCharType' => 'end'
              end
            end
          end
        end
        xml['w'].p paragraph_options do
          xml['w'].r do
            xml['w'].fldChar 'w:fldCharType' => 'end'
          end
        end
      end

      def render_link(xml, model)
        if model.external?
          rel = document.relationship({ target: model.link_href, type: :link })
          hyperlink_options = { 'r:id' => rel.formatted_id }
        else
          hyperlink_options = { 'w:anchor' => model.link_href }
        end

        xml['w'].hyperlink(hyperlink_options) do
          xml['w'].r run_options do
            render_run_attributes(xml, model, false)
            xml['w'].t({ 'xml:space' => 'preserve' }, model.link_content)
          end
        end
      end

      def render_list(xml, model)
        if model.list_level == 0
          document.toplevel_lists << model
          list_num = document.toplevel_lists.length   # numbering uses 1-based index
        end

        model.recursive_items.each do |item|
          render_listitem(xml, item, list_num)
        end
      end

      def render_listitem(xml, model, list_num)
        ls      = document.find_list_style(model.list_item_type, model.list_item_level)
        hanging = ls.style_left.to_i - ls.style_indent.to_i - 1

        xml['w'].p paragraph_options do
          xml['w'].pPr do
            xml['w'].numPr do
              xml['w'].ilvl 'w:val' => model.list_item_level
              xml['w'].numId 'w:val' => list_num
            end
            xml['w'].ind 'w:start' => ls.style_left, 'w:hanging' => hanging
            xml['w'].contextualSpacing 'w:val' => '1'
            xml['w'].rPr do
              xml['w'].u 'w:val' => 'none'
            end
          end

          model.runs.each do |run|
            method = render_method_for_model(run)
            send(method, xml, run)
          end
        end
      end

      def render_pagebreak(xml, model)
        if model.page_break_wrap
          xml['w'].p paragraph_options do
            xml['w'].r run_options do
              xml['w'].br 'w:type' => 'page'
            end
          end
        else
          xml['w'].r run_options do
            xml['w'].br 'w:type' => 'page'
          end
        end
      end

      def render_paragraph(xml, model)
        run_props = [:color, :size, :bold, :italic, :underline].map { |m| model.send("paragraph_#{ m }") }.compact

        xml['w'].p paragraph_options do
          xml['w'].pPr do
            xml['w'].pStyle 'w:val' => model.paragraph_style unless model.paragraph_style.nil?
            xml['w'].jc 'w:val' => model.paragraph_align unless model.paragraph_align.nil?
            xml['w'].ind "w:#{model.indent[:side]}" => model.indent[:value] unless model.indent.nil?
            xml['w'].keepNext if model.paragraph_keep_next == true
            render_run_attributes(xml, model, true)
            if model.paragraph_tabs&.any?
              xml['w'].tabs do
                model.paragraph_tabs.each do |t|
                  case t
                  when Numeric
                    xml['w'].tab 'w:val' => 'start', 'w:pos' => t.to_i, 'w:leader' => 'none'
                  else
                    #raise t.inspect
                    xml['w'].tab 'w:val' => t[:val], 'w:pos' => t[:pos].to_i, 'w:leader' => (t[:leader] || 'none')
                  end
                end
              end
              xml['w'].contextualSpacing 'w:val' => '0'
            end

          end
          model.runs.each do |run|
            method = render_method_for_model(run)
            send(method, xml, run)
          end
        end
      end

      def render_rule(xml, model)
        options = { 'w:color' => model.rule_color, 'w:sz' => model.rule_size, 'w:val' => model.rule_line, 'w:space' => model.rule_spacing }

        xml['w'].p paragraph_options do
          xml['w'].pPr do
            xml['w'].pBdr do
              xml['w'].top options
            end
          end
        end
      end

      def render_text(xml, model)
        xml['w'].r run_options do
          render_run_attributes(xml, model, false)
          xml['w'].t({ 'xml:space' => 'preserve' }, model.text_content)
          xml['w'].tab if model.text_end_tab
        end
      end

      def render_field(xml, model)
        xml['w'].r run_options do
          render_run_attributes(xml, model, false)
          xml['w'].fldChar({ 'w:fldCharType' => 'begin' })
          xml['w'].instrText({ 'xml:space' => 'preserve' }) do
            xml.text model.field_name
          end
          xml['w'].fldChar({ 'w:fldCharType' => 'end' })
        end
      end

      def render_table(xml, model)
        borders = %w(top left bottom right horizontal vertical).select do |m|
          model.send("table_border_#{ m }_size") > 0
        end

        xml['w'].tbl do
          xml['w'].tblPr do
            xml['w'].tblStyle 'w:val' => 'DefaultTable'
            #xml['w'].bidiVisual 'w:val' => 'false'
            xml['w'].tblW 'w:w' => model.table_width.to_i, 'w:type' => 'dxa'
            xml['w'].jc 'w:val' => model.table_align
            xml['w'].tblInd 'w:w' => 0, 'w:type' => 'dxa'
            unless borders.empty?
              xml['w'].tblBorders do
                borders.each do |m|
                  options = {
                    'w:color' => model.send("table_border_#{ m }_color"),
                    'w:val'   => model.send("table_border_#{ m }_line"),
                    'w:sz'    => model.send("table_border_#{ m }_size"),
                    'w:space' => model.send("table_border_#{ m }_spacing")
                  }
                  xml['w'].method_missing "#{ Caracal::Core::Models::BorderModel.formatted_type(m) }", options
                end
              end
            end
            # TODO: w:shd [0..1]    Table Shading
            xml['w'].tblLayout 'w:type' => 'fixed'
            # TODO: w:tblCellMar [0..1]    Table Cell Margin Defaults
            xml['w'].tblLook 'w:val'  => '0600'
          end
          xml['w'].tblGrid do
            column_widths = model.table_column_widths
            column_widths ||= model.rows.first.map do |tc|
              [tc.cell_width] * (tc.cell_colspan || 1)
            end.flatten

            column_widths.each do |width|
              xml['w'].gridCol 'w:w' => width
            end

            #xml['w'].tblGridChange 'w:id' => '0' do
              #xml['w'].tblGrid do
                #column_widths.each do |width|
                  #xml['w'].gridCol 'w:w' => width
                #end
              #end
            #end
          end

          rowspan_hash = {}
          model.rows.each_with_index do |row, index|
            xml['w'].tr do
              if model.table_repeat_header > 0
                if index < model.table_repeat_header
                  xml['w'].trPr do
                    xml['w'].tblHeader
                  end
                end
              end
              row.each_with_index do |tc, tc_index|
                xml['w'].tc do
                  xml['w'].tcPr do
                    # applying colspan
                    if tc.cell_colspan
                      xml['w'].gridSpan 'w:val' => tc.cell_colspan
                    end

                    # applying rowspan
                    if tc.cell_rowspan && tc.cell_rowspan > 0
                      rowspan_hash[tc_index] = tc.cell_rowspan - 1
                      xml['w'].vMerge 'w:val' => 'restart'
                    elsif rowspan_hash[tc_index] && rowspan_hash[tc_index] > 0
                      xml['w'].vMerge 'w:val' => 'continue'
                      rowspan_hash[tc_index] -= 1
                    end

                    borders = %w(top left bottom right horizontal vertical).select do |m|
                      tc.send("cell_border_#{ m }_size") > 0
                    end
                    unless borders.empty?
                      xml['w'].tcBorders do
                        borders.each do |m|
                          options = {
                            'w:color' => tc.send("cell_border_#{ m }_color"),
                            'w:val'   => tc.send("cell_border_#{ m }_line"),
                            'w:sz'    => tc.send("cell_border_#{ m }_size"),
                            'w:space' => tc.send("cell_border_#{ m }_spacing")
                          }
                          xml['w'].method_missing "#{ Caracal::Core::Models::BorderModel.formatted_type(m) }", options
                        end
                      end
                    end

                    if tc.cell_background
                      xml['w'].shd 'w:fill' => tc.cell_background, 'w:val' => 'clear'
                    end

                    xml['w'].tcMar do
                      xml['w'].top    'w:w' => tc.send("cell_margin_top").to_i,    'w:type' => 'dxa'
                      xml['w'].start  'w:w' => tc.send("cell_margin_left").to_i,   'w:type' => 'dxa'
                      xml['w'].bottom 'w:w' => tc.send("cell_margin_bottom").to_i, 'w:type' => 'dxa'
                      xml['w'].end    'w:w' => tc.send("cell_margin_right").to_i,  'w:type' => 'dxa'
                    end

                    xml['w'].vAlign 'w:val' => tc.cell_vertical_align
                  end

                  tc.contents.each do |m|
                    method = render_method_for_model(m)
                    send(method, xml, m)
                  end
                end

                # adjust tc_index for next cell taking into account current cell's colspan
                tc_index += (tc.cell_colspan && tc.cell_colspan > 0) ? tc.cell_colspan : 1
              end
            end
          end
        end
      end

      #============= TABLE OF CONTENTS =========================

      # Returns all document headings (paragraphs with a style_id of HeadingX, X going from 1 to 6)
      def headings
        heading_styles = document.outline_styles.collect(&:style_id)
        document.contents.select do |model|
          model.respond_to?(:paragraph_style) && heading_styles.include?(model.paragraph_style) && !model.empty?
        end
      end

      # Returns a collection of hashes containing text, reference and level for the given models
      # TODO: allow listing figures and tables instead of only headings
      # TODO: allow limiting contents by section, as Word offers
      def bookmarks_for(headings)
        bookmarks = []
        headings.each do |heading|
          bookmarks << {
            ref: bookmark_for(heading),
            text: heading.plain_text,
            level: heading.try(:paragraph_style).match(/Heading(\d)\Z/) { |m| m[1] || 1 }
          }
        end
        bookmarks
      end

      # Returns the name (reference) of the first bookmark in the given model
      # Wraps the model contents in a bookmark if necessary
      def bookmark_for(model)
        if (run = model.runs.select { |run| run.is_a?(Caracal::Core::Models::BookmarkModel) }.first)
          run.bookmark_name
        else
          name = "_Toc#{ model.object_id }"
          model.runs.prepend(Caracal::Core::Models::BookmarkModel.new(start: true, name: name))
          model.runs.append(Caracal::Core::Models::BookmarkModel.new(start: false))
          name
        end
      end

      #============= OPTIONS ===================================

      def root_options
        opts = {}
        document.namespaces.each do |model|
          opts[model.namespace_prefix] = model.namespace_href
        end
        unless document.ignorables.empty?
          v = document.ignorables.join(' ')
          opts['mc:Ignorable'] = v
        end
        opts
      end

      def page_margin_options
        {
          'w:top'    => document.page_margin_top,
          'w:bottom' => document.page_margin_bottom,
          'w:left'   => document.page_margin_left,
          'w:right'  => document.page_margin_right
        }
      end

      def page_size_options
        {
          'w:w'       => document.page_width,
          'w:h'       => document.page_height,
          'w:orient'  => document.page_orientation
        }
      end

    end
  end
end
