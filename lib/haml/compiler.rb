require 'haml/attribute_builder'
require 'haml/attribute_compiler'
require 'haml/temple_line_counter'

module Haml
  class Compiler
    include Haml::Util

    attr_accessor :options

    def initialize(options)
      @options     = Options.wrap(options)
      @output_tabs = 0
      @to_merge    = []
      @temple      = [:multi]
      @node        = nil
      @attribute_compiler = AttributeCompiler.new(@options)
    end

    def call(node)
      compile(node)
      @temple
    end

    def compile(node)
      parent, @node = @node, node
      if node.children.empty?
        send(:"compile_#{node.type}")
      else
        send(:"compile_#{node.type}") {node.children.each {|c| compile c}}
      end
    ensure
      @node = parent
    end

    private

    def compile_root
      @output_line = 1
      yield if block_given?
      flush_merged_text
    end

    def compile_plain
      push_text @node.value[:text]
    end

    def nuke_inner_whitespace?(node)
      if node.value && node.value[:nuke_inner_whitespace]
        true
      elsif node.parent
        nuke_inner_whitespace?(node.parent)
      else
        false
      end
    end

    def compile_script(&block)
      push_script(@node.value[:text],
                  :preserve_script       => @node.value[:preserve],
                  :escape_html           => @node.value[:escape_html],
                  :nuke_inner_whitespace => nuke_inner_whitespace?(@node),
                  &block)
    end

    def compile_silent_script
      return if @options.suppress_eval
      push_silent(@node.value[:text])
      keyword = @node.value[:keyword]

      if block_given?
        yield
        push_silent("end", :can_suppress) unless @node.value[:dont_push_end]
      elsif keyword == "end"
        if @node.parent.children.last.equal?(@node)
          # Since this "end" is ending the block,
          # we don't need to generate an additional one
          @node.parent.value[:dont_push_end] = true
        end
        # Don't restore dont_* for end because it isn't a conditional branch.
      end
    end

    def compile_haml_comment; end

    def compile_tag
      t = @node.value

      # Get rid of whitespace outside of the tag if we need to
      rstrip_buffer! if t[:nuke_outer_whitespace]

      if @options.suppress_eval
        object_ref = :nil
        parse = false
        value = t[:parse] ? nil : t[:value]
        attributes_hashes = []
        preserve_script = false
      else
        object_ref = t[:object_ref]
        parse = t[:parse]
        value = t[:value]
        attributes_hashes = t[:attributes_hashes]
        preserve_script = t[:preserve_script]
      end

      if @options[:trace]
        t[:attributes].merge!({"data-trace" => @options.filename.split('/views').last << ":" << @node.line.to_s})
      end

      push_merged_text "<#{t[:name]}"
      push_temple(@attribute_compiler.compile(t[:attributes], object_ref, attributes_hashes))
      concat_merged_text(
        if t[:self_closing] && @options.xhtml?
          " />#{"\n" unless t[:nuke_outer_whitespace]}"
        else
          ">#{"\n" unless (t[:self_closing] && @options.html?) ? t[:nuke_outer_whitespace] : (!block_given? || t[:preserve_tag] || t[:nuke_inner_whitespace])}"
        end)

      if value && !parse
        concat_merged_text("#{value}</#{t[:name]}>#{"\n" unless t[:nuke_outer_whitespace]}")
      elsif !t[:nuke_inner_whitespace] && !t[:self_closing]
        @to_merge << [:text, '']
      end

      return if t[:self_closing]

      if value.nil?
        @output_tabs += 1 unless t[:nuke_inner_whitespace]
        yield if block_given?
        @output_tabs -= 1 unless t[:nuke_inner_whitespace]
        rstrip_buffer! if t[:nuke_inner_whitespace]
        push_merged_text("</#{t[:name]}>#{"\n" unless t[:nuke_outer_whitespace]}")
        return
      end

      if parse
        push_script(value, t.merge(:in_tag => true))
        concat_merged_text("</#{t[:name]}>#{"\n" unless t[:nuke_outer_whitespace]}")
      end
    end

    def compile_comment
      condition = "#{@node.value[:conditional]}>" if @node.value[:conditional]
      revealed = @node.value[:revealed]

      open = "<!--#{condition}#{'<!-->' if revealed}"

      close = "#{'<!--' if revealed}#{'<![endif]' if condition}-->"

      unless block_given?
        push_merged_text("#{open} ")

        if @node.value[:parse]
          push_script(@node.value[:text], :in_tag => true, :nuke_inner_whitespace => true)
        else
          push_merged_text(@node.value[:text])
        end

        push_merged_text(" #{close}\n")
        return
      end

      push_text(open)
      @output_tabs += 1
      yield if block_given?
      @output_tabs -= 1
      push_text(close)
    end

    def compile_doctype
      doctype = text_for_doctype
      push_text doctype if doctype
    end

    def compile_filter
      unless filter = Filters.defined[@node.value[:name]]
        name = @node.value[:name]
        if ["maruku", "textile"].include?(name)
          raise Error.new(Error.message(:install_haml_contrib, name), @node.line - 1)
        else
          raise Error.new(Error.message(:filter_not_defined, name), @node.line - 1)
        end
      end
      filter.internal_compile(self, @node.value[:text])
    end

    def text_for_doctype
      if @node.value[:type] == "xml"
        return nil if @options.html?
        wrapper = @options.attr_wrapper
        return "<?xml version=#{wrapper}1.0#{wrapper} encoding=#{wrapper}#{@node.value[:encoding] || "utf-8"}#{wrapper} ?>"
      end

      if @options.html5?
        '<!DOCTYPE html>'
      else
        if @options.xhtml?
          if @node.value[:version] == "1.1"
            '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">'
          elsif @node.value[:version] == "5"
            '<!DOCTYPE html>'
          else
            case @node.value[:type]
            when "strict";   '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">'
            when "frameset"; '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Frameset//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-frameset.dtd">'
            when "mobile";   '<!DOCTYPE html PUBLIC "-//WAPFORUM//DTD XHTML Mobile 1.2//EN" "http://www.openmobilealliance.org/tech/DTD/xhtml-mobile12.dtd">'
            when "rdfa";     '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML+RDFa 1.0//EN" "http://www.w3.org/MarkUp/DTD/xhtml-rdfa-1.dtd">'
            when "basic";    '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML Basic 1.1//EN" "http://www.w3.org/TR/xhtml-basic/xhtml-basic11.dtd">'
            else             '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">'
            end
          end

        elsif @options.html4?
          case @node.value[:type]
          when "strict";   '<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01//EN" "http://www.w3.org/TR/html4/strict.dtd">'
          when "frameset"; '<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01 Frameset//EN" "http://www.w3.org/TR/html4/frameset.dtd">'
          else             '<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">'
          end
        end
      end
    end

    # Evaluates `text` in the context of the scope object, but
    # does not output the result.
    def push_silent(text, can_suppress = false)
      flush_merged_text
      return if can_suppress && @options.suppress_eval?
      newline = (text == "end") ? ";" : "\n"
      @temple << [:code, "#{resolve_newlines}#{text}#{newline}"]
      @output_line = @output_line + text.count("\n") + newline.count("\n")
    end

    # Adds `text` to `@buffer` with appropriate tabulation
    # without parsing it.
    def push_merged_text(text)
      @to_merge << [:text, text]
    end

    # Concatenate `text` to `@buffer` without tabulation.
    def concat_merged_text(text)
      @to_merge << [:text, text]
    end

    def push_text(text)
      push_merged_text("#{text}\n")
    end

    # This method is only supported for `@options.ugly` case.
    def push_temple(temple)
      newlines = resolve_newlines
      @to_merge << [:temple, [:code, newlines]] unless newlines.empty?
      @to_merge << [:temple, temple]
      @output_line += TempleLineCounter.count_lines(temple)
    end

    def flush_merged_text
      return if @to_merge.empty?

      @to_merge.each do |type, val|
        case type
        when :text
          @temple << [:static, val]
        when :script
          @temple << [:dynamic, val]
        when :temple
          @temple << val
        else
          raise SyntaxError.new("[HAML BUG] Undefined entry in Haml::Compiler@to_merge.")
        end
      end

      @to_merge = []
    end

    # Causes `text` to be evaluated in the context of
    # the scope object and the result to be added to `@buffer`.
    #
    # If `opts[:preserve_script]` is true, Haml::Helpers#find_and_preserve is run on
    # the result before it is added to `@buffer`
    def push_script(text, opts = {})
      return if @options.suppress_eval?

      args = [:preserve_script, :in_tag, :preserve_tag, :escape_html, :nuke_inner_whitespace]
      args.map! {|name| !!opts[name]}
      args << !block_given?

      no_format = !(opts[:preserve_script] || opts[:preserve_tag] || opts[:escape_html])

      # Prerender tabulation unless we're in a tag
      push_merged_text '' unless opts[:in_tag]

      unless block_given?
        format_script_method = "_hamlout.format_script((#{text}\n),#{args.join(',')});"
        push_generated_script(no_format ? "(#{text}\n).to_s" : format_script_method)
        concat_merged_text("\n") unless opts[:in_tag] || opts[:nuke_inner_whitespace]
        return
      end

      flush_merged_text
      push_silent "haml_temp = #{text}"
      yield
      push_silent('end', :can_suppress) unless @node.value[:dont_push_end]
      format_script_method = "_hamlout.format_script(haml_temp,#{args.join(',')});"
      @temple << [:dynamic, no_format ? "haml_temp.to_s;" : format_script_method]
    end

    def push_generated_script(text)
      @to_merge << [:script, resolve_newlines + text]
      @output_line += text.count("\n")
    end

    def resolve_newlines
      diff = @node.line - @output_line
      return "" if diff <= 0
      @output_line = @node.line
      "\n" * diff
    end

    # Get rid of and whitespace at the end of the buffer
    # or the merged text
    def rstrip_buffer!(index = -1)
      last = @to_merge[index]
      if last.nil?
        push_silent("_hamlout.rstrip!", false)
        return
      end

      case last.first
      when :text
        last[1].rstrip!
        if last[1].empty?
          @to_merge.slice! index
          rstrip_buffer! index
        end
      when :script
        last[1].gsub!(/\(haml_temp, (.*?)\);$/, '(haml_temp.rstrip, \1);')
        rstrip_buffer! index - 1
      else
        raise SyntaxError.new("[HAML BUG] Undefined entry in Haml::Compiler@to_merge.")
      end
    end
  end
end
