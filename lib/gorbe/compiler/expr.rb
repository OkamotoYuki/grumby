module Gorbe
  module Compiler

    # A class which stands an expression in generated Go code.
    class Expr
      attr_reader :name
      attr_reader :type
      attr_reader :expr

      def initialize(block: nil, name: '', type: nil, expr: nil)
        @block = block
        @name = name
        @type = type
        @expr = expr
      end

      def free
      end
    end

    # A class which stands an expression result stored in a temporary value.
    class TempVar < Expr
      def initialize(block: nil, name: '', type: nil)
        super(block: block, name: name, type: type, expr: name)
      end

      def free
        @block.free_temp(self)
      end
    end

    # A class which stands Go local var corresponding to a Python local.
    class LocalVar < Expr
      def initialize(name='')
        super(name: name, expr: Util::get_go_identifier(name))
      end
    end

    # A class which stands a literal in generated Go code.
    class Literal < Expr
      def initialize(expr=nil)
        super(expr: expr)
      end

    end

    NIL_EXPR = Literal.new('nil')

    # A class which generates Go code based on Ruby AST (Expression).
    class ExprVisitor < Visitor

      BIN_OP_TEMPLATES = {
          :"&&" => lambda { |lhs, rhs| "πg.And(πF, #{lhs}, #{rhs})" },  # FIXME : πg.And() is actually 'Bit And' and not 'Logical And'
          :"||" => lambda { |lhs, rhs| "πg.Or(πF, #{lhs}, #{rhs})" },   # FIXME : πg.Or() is actually 'Bit Or' and not 'Logical Or'
          :^ => lambda { |lhs, rhs| "πg.Xor(πF, #{lhs}, #{rhs})" },
          :+ => lambda { |lhs, rhs| "πg.Add(πF, #{lhs}, #{rhs})" },
          :/ => lambda { |lhs, rhs| "πg.Div(πF, #{lhs}, #{rhs})" },
          # :// => lambda { |lhs, rhs | "πg.FloorDiv(πF, #{lhs}, #{rhs})" },
          :<< => lambda { |lhs, rhs| "πg.LShift(πF, #{lhs}, #{rhs})" },
          :% => lambda { |lhs, rhs| "πg.Mod(πF, #{lhs}, #{rhs})" },
          :* => lambda { |lhs, rhs| "πg.Mul(πF, #{lhs}, #{rhs})" },
          :** => lambda { |lhs, rhs| "πg.Pow(πF, #{lhs}, #{rhs})" },
          :>> => lambda { |lhs, rhs| "πg.RShift(πF, #{lhs}, #{rhs})" },
          :- => lambda { |lhs, rhs| "πg.Sub(πF, #{lhs}, #{rhs})" },
          :== => lambda { |lhs, rhs| "πg.Eq(πF, #{lhs}, #{rhs})" },
          :> => lambda { |lhs, rhs| "πg.GT(πF, #{lhs}, #{rhs})" },
          :>= => lambda { |lhs, rhs| "πg.GE(πF, #{lhs}, #{rhs})" },
          :< => lambda { |lhs, rhs| "πg.LT(πF, #{lhs}, #{rhs})" },
          :<= => lambda { |lhs, rhs| "πg.LE(πF, #{lhs}, #{rhs})" },
          :!= => lambda { |lhs, rhs| "πg.NE(πF, #{lhs}, #{rhs})" }
      }

      UNARY_OP_TEMPLATES = {
          :~ => lambda { |operand| "πg.Invert(πF, #{operand})" },
          :-@ => lambda { |operand| "πg.Neg(πF, #{operand})" }
      }

      def initialize(stmt_visitor)
        super(block: stmt_visitor.block, parent: stmt_visitor, writer:  stmt_visitor.writer, nodetype_map:
            {
                array: 'array',
                aref: 'aref',
                assign: 'assign',
                assoclist_from_args: 'assoclist_from_args',
                assoc_new: 'assoc_new',
                binary: 'binary',
                hash: 'hash',
                '@ident': 'ident',
                unary: 'unary',
                var_field: 'var_field',
                var_ref: 'var_ref',
                string_literal: 'string_literal',
                string_content: 'string_content',
                '@int': 'num',
                '@float': 'num',
                '@kw': 'kw',
                '@tstring_content': 'tstring_content',
                method_add_arg: 'method_add_arg',
                fcall: 'fcall',
                call: 'call',
                arg_paren: 'arg_paren',
                args_add_block: 'args_add_block',
                const_ref: 'const_ref',
                '@const': 'const',
                '.': 'dot'
            }
        )
      end

      # e.g. [:binary, [:@int, "1", [1, 0]], :+, [:@int, "1", [1, 4]]]
      def visit_binary(node)
        raise CompileError.new(node, msg: 'Node size must be 4.') unless node.length == 4
        lhs = visit(node[1])&.expr
        operator = node[2]
        rhs = visit(node[3])&.expr
        raise CompileError.new(node, msg: 'There is lack of operands.') unless lhs && rhs

        result = @block.alloc_temp

        if BIN_OP_TEMPLATES.has_key?(operator) then
          call = BIN_OP_TEMPLATES[operator].call(lhs, rhs)
          @writer.write_checked_call2(result, call)
        elsif operator === :=== then
          @writer.write("#{result.name} = πg.GetBool(#{lhs} == #{rhs}).ToObject()")
        else
          raise CompileError.new(node, msg: "The operator '#{operator}' is not supported. " +
              'Please contact us via https://github.com/okamotoyuki/gorbe/issues.')
        end

        return result
      end

      # e.g. [:unary, :-@, [:@int, "123", [1, 1]]]
      def visit_unary(node)
        raise CompileError.new(node, msg: 'Node size must be 3.') unless node.length == 3

        operator = node[1]
        operand = visit(node[2])&.expr
        raise CompileError.new(node, msg: 'There is lack of operands.') unless operand

        result = @block.alloc_temp

        if UNARY_OP_TEMPLATES.has_key?(operator) then
          call = UNARY_OP_TEMPLATES[operator].call(operand)
          @writer.write_checked_call2(result, call)
        elsif operator === :not
          is_true = @block.alloc_temp('bool')
          @writer.write_checked_call2(is_true, "πg.IsTrue(πF, #{operand})")
          @writer.write("#{result.name} = πg.GetBool(!#{is_true.expr}).ToObject()")
        else
          raise CompileError.new(node, msg: "The operator '#{operator}' is not supported. " +
              'Please contact us via https://github.com/okamotoyuki/gorbe/issues.')
        end

        return result
      end

      # e.g. [:var_ref, [:@kw, "true", [1, 0]]]
      def visit_var_ref(node)
        raise CompileError.new(node, msg: 'Node size must be 2.') unless node.length == 2

        var_node = node[1]
        case var_node[0]
        when '@kw'.to_sym, '@ident'.to_sym, '@const'.to_sym then
          var = visit_typed_node(var_node, var_node[0])
        else
          raise CompileError.new(node, msg: "'#{var_node[0]}' is unexpected variable type in this context. " +
              'Please contact us via https://github.com/okamotoyuki/gorbe/issues.')
        end
        raise CompileError.new(node, msg: 'Variable mult not be nil.') if var.nil?

        return @block.resolve_name(@writer, var)
      end

      # e.g. [:@kw, "true", [1, 0]]
      def visit_kw(node)
        raise CompileError.new(node, msg: 'Node size must be 3.') unless node.length == 3

        return node[1]
      end

      # e.g. [:@int, "1", [1, 0]]
      def visit_num(node)
        raise CompileError.new(node, msg: 'Node size must be 3.') unless node.length == 3

        type = node[0]
        number = node[1]
        case type
        when :@int then
          expr_str = "NewInt(%d)" % number
        when :@float then
          expr_str = "NewFloat(%f)" % number
        else
          raise CompileError.new(node, "The number type '#{type}' is not supported ." +
              'Please contact us via https://github.com/okamotoyuki/gorbe/issues.')
        end

        return Literal.new('πg.' + expr_str + '.ToObject()')
      end

      # e.g. [:string_literal, [:string_content, [:@tstring_content, "this is a string expression\\n", [1, 1]]]]
      def visit_string_literal(node)
        raise CompileError.new(node, msg: 'Node size must be 2.') unless node.length == 2

        # TODO : Check if the string is unicode and generate 'πg.NewUnicode({}).ToObject()'

        return visit_typed_node(node[1], :string_content)
      end

      # e.g. [:string_content, [:@tstring_content, "this is a string expression\\n", [1, 1]]]
      def visit_string_content(node)
        raise CompileError.new(node, msg: 'Node size must be 2.') unless node.length == 2

        return visit_typed_node(node[1], '@tstring_content'.to_sym)
      end

      # e.g. [:@tstring_content, "this is a string expression\\n", [1, 1]]
      def visit_tstring_content(node)
        raise CompileError.new(node, msg: 'Node size must be 3.') unless node.length == 3

        str = node[1]
        expr_str = "%s.ToObject()" % @block.root.intern(str)
        return Literal.new(expr_str)
      end

      # e.g. [:array, [[:@int, "1", [1, 1]], [:@int, "2", [1, 4]], [:@int, "3", [1, 7]]]
      def visit_array(node)
        raise CompileError.new(node, msg: 'Node size must be more than 1.') unless node.length > 1

        result = nil
        with(visit_sequential_elements(node[1])) do |elems|
          result = @block.alloc_temp
          @writer.write("#{result.expr} = πg.NewList(#{elems.expr}...).ToObject()")
        end
        return result
      end

      # e.g. [:aref, [:var_ref, [:@ident, "foo", [2, 2]]], [:args_add_block, [[:@int, "0", [2, 6]]], false]]
      def visit_aref(node)
        raise CompileError.new(node, msg: 'Node size must be 3.') unless node.length == 3

        result = self.block.alloc_temp()
        with(visit(node[2])[:argv], visit(node[1])) do |rhs, lhs|
          @writer.write_checked_call2(result, "πg.GetItem(πF, #{lhs.expr}, #{rhs.expr}[0])")
        end
        return result
      end

      private def visit_sequential_elements(nodes)
        result = @block.alloc_temp('[]*πg.Object')
        @writer.write("#{result.expr} = make([]*πg.Object, #{nodes.length})")

        visit(nodes) do |element, i|
          with(element) do |elem|
           @writer.write("#{result.expr}[#{i}] = #{elem.expr}")
          end
        end

        return result
      end

      # e.g. [:hash, [:assoclist_from_args, [[:assoc_new, [:@int, "1", [1, 2]], [:@int, "2", [1, 7]]]]]]
      def visit_hash(node)
        raise CompileError.new(node, msg: 'Node size must be 2.') unless node.length == 2

        result = nil
        with(@block.alloc_temp('*πg.Dict')) do |hash|
          @writer.write("#{hash.name} = πg.NewDict()")
          visit_typed_node(node[1], :assoclist_from_args, hash: hash)
          result = @block.alloc_temp
          @writer.write("#{result.name} = #{hash.expr}.ToObject()")
        end

        return result
      end

      # e.g. [:assoclist_from_args, [[:assoc_new, [:@int, "1", [1, 2]], [:@int, "2", [1, 7]]]]]
      def visit_assoclist_from_args(node, hash:)
        raise CompileError.new(node, msg: 'Node must have Array.') unless node[1].is_a?(Array)

        node[1].each do |assoc_new_node|
          visit_typed_node(assoc_new_node, :assoc_new, hash: hash)
        end
      end

      # e.g. [:assoc_new, [:@int, "1", [1, 2]], [:@int, "2", [1, 7]]]
      def visit_assoc_new(node, hash:)
        raise CompileError.new(node, msg: 'Node size must be 3.') unless node.length == 3

        with(visit(node[1]), visit(node[2])) do |key, value|
          @writer.write_checked_call1("#{hash.expr}.SetItem(πF, #{key.expr}, #{value.expr})")
        end
      end

      # e.g. [:assign, [:var_field, [:@ident, "foo", [1, 0]]], [:@int, "1", [1, 6]]]
      def visit_assign(node)
        raise CompileError.new(node, msg: 'Node size must be 3.') unless node.length == 3

        with(visit(node[2])) do |value|
          target = visit_typed_node(node[1], :var_field)
          @block.bind_var(@writer, target, value.expr)
        end
      end

      # e.g. [:@ident, "foo", [1, 0]]
      def visit_ident(node)
        raise CompileError.new(node, msg: 'Node size must be 3.') unless node.length == 3

        return node[1]
      end

      # e.g. [:var_field, [:@ident, "foo", [1, 0]]]
      def visit_var_field(node)
        raise CompileError.new(node, msg: 'Node size must be 2.') unless node.length == 2

        return visit_typed_node(node[1], '@ident'.to_sym)
      end

      # e.g. [:method_add_arg,
      #       [:fcall, [:@ident, "puts", [1, 0]]],
      #       [:arg_paren, [:args_add_block, [[:@int, "1", [1, 5]]], false]]]
      def visit_method_add_arg(node)
        raise CompileError.new(node, msg: 'Node size must be 3.') unless node.length == 3

        arg_info = visit_typed_node(node[2], :arg_paren)
        argc = arg_info[:argc]
        argv = arg_info[:argv]
        result = nil

        with(argv, visit(node[1])) do |args, func|
          result = @block.alloc_temp
          @writer.write_checked_call2(result, "#{func.expr}.Call(πF, #{args.expr}, #{NIL_EXPR.expr})")
        end

        if argc > 0
          @writer.write("πF.FreeArgs(#{argv.expr})")
        end

        return result
      end

      # e.g. [:fcall, [:@ident, "puts", [1, 0]]],
      def visit_fcall(node)
        raise CompileError.new(node, msg: 'Node size must be 3.') unless node.length == 2

        return @block.resolve_name(@writer, visit_typed_node(node[1], '@ident'.to_sym))
      end

      # e.g. [:call, [:var_ref, [:@const, "Foo", [7, 0]]], :".", [:@ident, "new", [7, 4]]]
      def visit_call(node)
        raise CompileError.new(node, msg: 'Node size must be 4.') unless node.length == 4

        attr = visit_typed_node(node[3], '@ident'.to_sym)

        # If the method name is 'new', invoke constructor.
        return visit_typed_node(node[1], :var_ref) if attr === 'new'

        result = nil
        with(visit_typed_node(node[1], :var_ref)) do |obj|
          result = @block.alloc_temp
          operator = node[2]
          @writer.write_checked_call2(result, "πg.GetAttr(πF, #{obj.expr}, #{@block.root.intern(attr)}, nil)")
        end

        return result
      end

      # e.g. [:arg_paren, [:args_add_block, [[:@int, "1", [1, 5]]], false]]]
      def visit_arg_paren(node)
        raise CompileError.new(node, msg: 'Node size must be 2.') unless node.length == 2

        return node[1].nil? ?
                  { argc: 0, argv: NIL_EXPR } : visit_typed_node(node[1], :args_add_block)
      end

      # e.g. [:args_add_block, [[:@int, "1", [1, 5]]], false]]
      def visit_args_add_block(node)
        raise CompileError.new(node, msg: 'Node size must be 3.') unless node.length == 3

        # Build positional arguments.
        argc = node[1].length
        argv = NIL_EXPR

        unless node[1].empty?
          argv = self.block.alloc_temp('[]*πg.Object')
          @writer.write("#{argv.expr} = πF.MakeArgs(#{argc})")
          node[1].each_with_index do |node, i|
            with(visit(node)) do |arg|
              @writer.write("#{argv.expr}[#{i}] = #{arg.expr}")
            end
          end
        end

        return { argc: argc, argv: argv }
      end

      # e.g. [:const_ref, [:@const, "Foo", [1, 6]]]
      def visit_const_ref(node)
        raise CompileError.new(node, msg: 'Node size must be 2.') unless node.length == 2

        return visit_typed_node(node[1], '@const'.to_sym)
      end

      # e.g. [:@const, "Foo", [1, 6]]
      def visit_const(node)
        raise CompileError.new(node, msg: 'Node size must be 3.') unless node.length == 3

        return node[1]
      end
    end

  end
end
