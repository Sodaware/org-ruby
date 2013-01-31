begin
  require 'pygments'
rescue LoadError
  # Pygments is not supported so we try instead with CodeRay
  begin
    require 'coderay'
  rescue LoadError
    # No code syntax highlighting
  end
end

module Orgmode

  class HtmlOutputBuffer < OutputBuffer

    HtmlBlockTag = {
      :paragraph => "p",
      :ordered_list => "ol",
      :unordered_list => "ul",
      :list_item => "li",
      :definition_list => "dl",
      :definition_term => "dt",
      :definition_descr => "dd",
      :table => "table",
      :table_row => "tr",
      :quote => "blockquote",
      :example => "pre",
      :src => "pre",
      :inline_example => "pre",
      :center => "div",
      :heading1 => "h1",
      :heading2 => "h2",
      :heading3 => "h3",
      :heading4 => "h4",
      :heading5 => "h5",
      :heading6 => "h6"
    }

    attr_reader :options

    def initialize(output, opts = {})
      super(output)
      if opts[:decorate_title] then
        @title_decoration = " class=\"title\""
      else
        @title_decoration = ""
      end
      @buffer_tag = "HTML"
      @options = opts
      @new_paragraph = :start
      @footnotes = {}
      @unclosed_tags = []
      @logger.debug "HTML export options: #{@options.inspect}"
    end

    # Output buffer is entering a new mode. Use this opportunity to
    # write out one of the block tags in the HtmlBlockTag constant to
    # put this information in the HTML stream.
    def push_mode(mode, indent)
      super(mode)
      @list_indent_stack.push(indent)

      if HtmlBlockTag[mode]
        unless ((mode_is_table?(mode) and skip_tables?) or
                (mode == :src and defined? Pygments))
          css_class = case
                      when (mode == :src and @block_lang.empty?)
                        " class=\"src\""
                      when (mode == :src and not @block_lang.empty?)
                        " class=\"src src-#{@block_lang}\""
                      when (mode == :example || mode == :inline_example)
                        " class=\"example\""
                      when mode == :center
                        " style=\"text-align: center\""
                      else
                        @title_decoration
                      end

          add_paragraph unless @new_paragraph == :start
          @new_paragraph = true

          @logger.debug "#{mode}: <#{HtmlBlockTag[mode]}#{css_class}>"
          @output << "<#{HtmlBlockTag[mode]}#{css_class}>"
          # Entering a new mode obliterates the title decoration
          @title_decoration = ""
        end
      end
    end

    # We are leaving a mode. Close any tags that were opened when
    # entering this mode.
    def pop_mode(mode = nil)
      m = super(mode)
      if HtmlBlockTag[m]
        unless ((mode_is_table?(m) and skip_tables?) or
                (m == :src and defined? Pygments))
          add_paragraph if @new_paragraph
          @new_paragraph = true
          @logger.debug "</#{HtmlBlockTag[m]}>"
          @output << "</#{HtmlBlockTag[m]}>"
        end
      end
      @list_indent_stack.pop
    end

    def flush!
      case
      when preserve_whitespace?
        strip_code_block! if mode_is_code? current_mode

        # NOTE: CodeRay and Pygments already escape the html once, so
        # no need to escape_buffer!
        case
        when (current_mode == :src and defined? Pygments)
          lang = normalize_lang @block_lang
          @output << "\n" unless @new_paragraph == :start

          begin
            @buffer = Pygments.highlight(@buffer, :lexer => lang)
          rescue
            # Not supported lexer from Pygments, we fallback on using the text lexer
            @buffer = Pygments.highlight(@buffer, :lexer => 'text')
          end
        when (current_mode == :src and defined? CodeRay)
          lang = normalize_lang @block_lang

          # CodeRay might throw a warning when unsupported lang is set,
          # then fallback to using the text lexer
          silence_warnings do
            begin
              @buffer = CodeRay.scan(@buffer, lang).html(:wrap => nil, :css => :style)
            rescue ArgumentError
              @buffer = CodeRay.scan(@buffer, 'text').html(:wrap => nil, :css => :style)
            end
          end
        else
          escape_buffer!
        end

        # Whitespace is significant in :code mode. Always output the
        # buffer and do not do any additional translation.
        @logger.debug "FLUSH CODE ==========> #{@buffer.inspect}"
        @output << @buffer

      when (mode_is_table? current_mode and skip_tables?)
        @logger.debug "SKIP       ==========> #{current_mode}"

      when (current_mode == :raw_text and @buffer.length > 0)
        @new_paragraph = true
        @output << "\n" unless @new_paragraph == :start
        @output << @buffer

      when @buffer.length > 0
        @buffer.lstrip!
        escape_buffer!
        @new_paragraph = nil
        @logger.debug "FLUSH      ==========> #{current_mode}"

        case current_mode
        when :definition_term
          d = @buffer.split("::", 2)
          @output << inline_formatting(d[0].strip)
          indent = @list_indent_stack.last
          pop_mode

          @new_paragraph = :start
          push_mode(:definition_descr, indent)
          @output << inline_formatting(d[1].strip)
          @new_paragraph = nil

        when :horizontal_rule
          add_paragraph unless @new_paragraph == :start
          @new_paragraph = true
          @output << "<hr />"

        else
          @output << inline_formatting(@buffer)
        end
      end
      @buffer = ""
    end

    def add_line_attributes headline
      if @options[:export_heading_number] then
        level = headline.level
        heading_number = get_next_headline_number(level)
        @output << "<span class=\"heading-number heading-number-#{level}\">#{heading_number} </span>"
      end
      if @options[:export_todo] and headline.keyword then
        keyword = headline.keyword
        @output << "<span class=\"todo-keyword #{keyword}\">#{keyword} </span>"
      end
    end

    def output_footnotes!
      return false unless @options[:export_footnotes] and not @footnotes.empty?

      @output << "\n<div id=\"footnotes\">\n<h2 class=\"footnotes\">Footnotes:</h2>\n<div id=\"text-footnotes\">\n"

      @footnotes.each do |name, defi|
        @output << "<p class=\"footnote\"><sup><a class=\"footnum\" name=\"fn.#{name}\" href=\"#fnr.#{name}\">#{name}</a></sup>" \
                << inline_formatting(defi) \
                << "\n</p>\n"
      end

      @output << "</div>\n</div>"

      return true
    end


    ######################################################################
    private

    def skip_tables?
      @options[:skip_tables]
    end

    def mode_is_table?(mode)
      (mode == :table or mode == :table_row or
       mode == :table_separator or mode == :table_header)
    end

    # Escapes any HTML content in the output accumulation buffer @buffer.
    def escape_buffer!
      @buffer.gsub!(/&/, "&amp;")
      @buffer.gsub!(/</, "&lt;")
      @buffer.gsub!(/>/, "&gt;")
    end

    def buffer_indentation
      indent = "  " * @list_indent_stack.length
      @buffer << indent
    end

    def add_paragraph
      indent = "  " * (@list_indent_stack.length - 1)
      @output << "\n" << indent
    end

    Tags = {
      "*" => { :open => "<b>", :close => "</b>" },
      "/" => { :open => "<i>", :close => "</i>" },
      "_" => { :open => "<span style=\"text-decoration:underline;\">",
        :close => "</span>" },
      "=" => { :open => "<code>", :close => "</code>" },
      "~" => { :open => "<code>", :close => "</code>" },
      "+" => { :open => "<del>", :close => "</del>" }
    }

    # Applies inline formatting rules to a string.
    def inline_formatting(str)
      @re_help.rewrite_emphasis str do |marker, s|
        "#{Tags[marker][:open]}#{s}#{Tags[marker][:close]}"
      end
      if @options[:use_sub_superscripts] then
        @re_help.rewrite_subp str do |type, text|
          if type == "_" then
            "<sub>#{text}</sub>"
          elsif type == "^" then
            "<sup>#{text}</sup>"
          end
        end
      end
      @re_help.rewrite_images str do |link|
        "<a href=\"#{link}\"><img src=\"#{link}\" /></a>"
      end
      @re_help.rewrite_links str do |link, text|
        text ||= link
        link = link.sub(/^file:(.*)::(.*?)$/) do

          # We don't support search links right now. Get rid of it.

          "file:#{$1}"
        end
        if link.match(/^file:.*\.org$/)
          link = link.sub(/\.org$/i, ".html")
        end

        link = link.sub(/^file:/i, "") # will default to HTTP

        text = text.gsub(/([^\]]*\.(jpg|jpeg|gif|png))/xi) do |img_link|
          "<img src=\"#{img_link}\" />"
        end
        "<a href=\"#{link}\">#{text}</a>"
      end
      if (@output_type == :table_row) then
        str.gsub!(/^\|\s*/, "<td>")
        str.gsub!(/\s*\|$/, "</td>")
        str.gsub!(/\s*\|\s*/, "</td><td>")
      end
      if (@output_type == :table_header) then
        str.gsub!(/^\|\s*/, "<th>")
        str.gsub!(/\s*\|$/, "</th>")
        str.gsub!(/\s*\|\s*/, "</th><th>")
      end
      if @options[:export_footnotes] then
        @re_help.rewrite_footnote str do |name, defi|
          # TODO escape name for url?
          @footnotes[name] = defi if defi
          "<sup><a class=\"footref\" name=\"fnr.#{name}\" href=\"#fn.#{name}\">#{name}</a></sup>"
        end
      end
      Orgmode.special_symbols_to_html(str)
      str = @re_help.restore_code_snippets str
      str
    end

    def normalize_lang(lang)
      case lang
      when 'emacs-lisp', 'common-lisp', 'lisp'
        'scheme'
      when ''
        'text'
      else
        lang
      end
    end

    # Helper method taken from Rails
    # https://github.com/rails/rails/blob/c2c8ef57d6f00d1c22743dc43746f95704d67a95/activesupport/lib/active_support/core_ext/kernel/reporting.rb#L10
    def silence_warnings
      warn_level = $VERBOSE
      $VERBOSE = nil
      yield
    ensure
      $VERBOSE = warn_level
    end

    def strip_code_block!
      strip_regexp = Regexp.new('\n' + ' ' * @code_block_indent)
      @buffer.gsub!(strip_regexp, "\n")
      @code_block_indent = nil
    end
  end                           # class HtmlOutputBuffer
end                             # module Orgmode
