require "./repl_interface/repl_interface"

class IC::PryInterface < IC::ReplInterface::ReplInterface
  def self.new
    new do |_, color?|
      "ic(#{Crystal::Config.version}):#{"pry".colorize(:magenta).toggle(color?)}> "
    end
  end

  def on_ctrl_up
    yield "whereami"
  end

  def on_ctrl_down
    yield "next"
  end

  def on_ctrl_left
    yield "finish"
  end

  def on_ctrl_right
    yield "step"
  end
end

# from compiler/crystal/interpreter/interpreter.cr: (1.3.0-dev)
class Crystal::Repl::Interpreter
  getter pry_interface = IC::PryInterface.new

  private def pry(ip, instructions, stack_bottom, stack)
    # We trigger keyboard interrupt here because only 'pry' can interrupt the running program.
    if @keyboard_interrupt
      @stack.clear
      @call_stack = [] of CallFrame
      @call_stack_leave_index = 0
      @block_level = 0
      @compiled_def = nil
      @keyboard_interrupt = false
      self.pry = false
      raise KeyboardInterrupt.new
    end

    output = @pry_interface.output
    call_frame = @call_stack.last
    compiled_def = call_frame.compiled_def
    a_def = compiled_def.def
    local_vars = compiled_def.local_vars
    offset = (ip - instructions.instructions.to_unsafe).to_i32
    node = instructions.nodes[offset]?
    pry_node = @pry_node
    if node && (location = node.location) && different_node_line?(node, pry_node)
      whereami(a_def, location)

      # puts
      # puts Slice.new(stack_bottom, stack - stack_bottom).hexdump
      # puts

      # Remember the portion from stack_bottom + local_vars.max_bytesize up to stack
      # because it might happen that the child interpreter will overwrite some
      # of that if we already have some values in the stack past the local vars
      data_size = stack - (stack_bottom + local_vars.max_bytesize)
      data = Pointer(Void).malloc(data_size).as(UInt8*)
      data.copy_from(stack_bottom + local_vars.max_bytesize, data_size)

      gatherer = LocalVarsGatherer.new(location, a_def)
      gatherer.gather
      meta_vars = gatherer.meta_vars
      block_level = gatherer.block_level

      main_visitor = MainVisitor.new(
        @context.program,
        vars: meta_vars,
        meta_vars: meta_vars,
        typed_def: a_def)
      main_visitor.scope = compiled_def.owner
      main_visitor.path_lookup = compiled_def.owner # TODO: this is probably not right

      interpreter = Interpreter.new(self, compiled_def, stack_bottom, block_level)

      # IC MODIFICATION:
      @pry_interface.color = @context.program.color?
      @pry_interface.auto_completion.set_context(
        local_vars: interpreter.local_vars,
        program: @context.program,
        main_visitor: main_visitor,
        special_commands: %w(continue step next finish whereami),
      )

      @pry_interface.run do |line|
        # WAS:
        # while @pry
        #   TODO: supoort multi-line expressions

        #   print "pry> "
        #   line = gets
        # END
        unless line
          self.pry = false
          break
        end

        case line
        when "continue"
          self.pry = false
          break
        when "step"
          @pry_node = node
          @pry_max_target_frame = nil
          break
        when "next"
          @pry_node = node
          @pry_max_target_frame = @call_stack.last.real_frame_index
          break
        when "finish"
          @pry_node = node
          @pry_max_target_frame = @call_stack.last.real_frame_index - 1
          break
        when "whereami"
          whereami(a_def, location)
          next
        when "*d"
          output.puts compiled_def.local_vars
          output.puts Disassembler.disassemble(@context, compiled_def)
          next
        when "*s"
          output.puts Slice.new(@stack, stack - @stack).hexdump
          next
        end

        begin
          parser = Parser.new(
            line,
            string_pool: @context.program.string_pool,
            var_scopes: [interpreter.local_vars.names.to_set],
          )
          line_node = parser.parse

          line_node = @context.program.normalize(line_node)
          line_node = @context.program.semantic(line_node, main_visitor: main_visitor)

          value = interpreter.interpret(line_node, meta_vars)
          # IC MODIFICATION:
          output.puts " => #{IC::Highlighter.highlight(value.to_s, toggle: @context.program.color?)}"
          # WAS:
          # puts value.to_s
          # END

        rescue ex : Crystal::CodeError
          # IC MODIFICATION:
          ex.color = @context.program.color?
          # WAS:
          # ex.color = true
          # END
          ex.error_trace = true
          output.puts ex
          next
        rescue ex : Exception
          ex.inspect_with_backtrace(output)
          next
        end
      end
      # Restore the stack data in case it tas overwritten
      (stack_bottom + local_vars.max_bytesize).copy_from(data, data_size)
    end
  end

  private def whereami(a_def : Def, location : Location)
    filename = location.filename
    line_number = location.line_number
    column_number = location.column_number

    # IC ADDING:
    output = @pry_interface.output

    a_def_owner = @context.program.colorize(a_def.owner.to_s).blue.underline
    hashtag = @context.program.colorize("#").dark_gray.bold
    # END

    if filename.is_a?(String)
      # IC ADDING:
      return if filename.empty?
      # END

      output.puts "From: #{Crystal.relative_filename(filename)}:#{line_number}:#{column_number} #{a_def_owner}#{hashtag}#{a_def.name}:"
    else
      output.puts "From: #{location} #{a_def_owner}#{hashtag}#{a_def.name}:"
    end

    output.puts

    lines =
      case filename
      in String
        File.read_lines(filename)
      in VirtualFile
        filename.source.lines.to_a
      in Nil
        nil
      end

    return unless lines

    # IC ADDING:
    lines = IC::Highlighter.highlight(lines.join('\n'), toggle: @context.program.color?).split('\n')
    # END

    min_line_number = {location.line_number - 5, 1}.max
    max_line_number = {location.line_number + 5, lines.size}.min

    max_line_number_size = max_line_number.to_s.size

    min_line_number.upto(max_line_number) do |line_number|
      line = lines[line_number - 1]
      if line_number == location.line_number
        output.print " => "
      else
        output.print "    "
      end

      # IC ADDING:
      if (filename = location.filename).is_a? TopLevelExpressionVirtualFile
        line_number += filename.initial_line_number
      end
      # END

      # Pad line number if needed
      line_number_size = line_number.to_s.size
      (max_line_number_size - line_number_size).times do
        output.print ' '
      end

      # IC MODIFICATION:
      output.print @context.program.colorize(line_number).blue
      # WAS:
      # print line_number.colorize.blue
      # END
      output.print ": "
      output.puts line
    end
    output.puts
  end
end
