module IC::REPLInterface
  module CharReader
    def self.read_chars(io = STDIN, &)
      c = nil
      loop do
        io.raw { c = self.next_char(io) }
        break if c == :exit

        yield c if c
      end
    end

    private def self.next_char(io)
      c = io.read_char
      case c
      when '\e'
        if io.read_char == '['
          case io.read_char
          when 'A' then :up
          when 'B' then :down
          when 'C' then :right
          when 'D' then :left
          when '3'
            if io.read_char == '~'
              :delete
            end
          when '1'
            if io.read_char == ';' && io.read_char == '5'
              case io.read_char
              when 'A' then :ctrl_up
              when 'B' then :ctrl_down
              when 'C' then :ctrl_right
              when 'D' then :ctrl_left
              end
            end
          end
        end
      when '\r'
        :new_line
      when '\u0003', '\u0004', '\u0018'
        # ctrl-c, ctrl-d, ctrl-x
        :exit
      when '\u007f'
        :back
      else
        c
      end
    end
  end
end