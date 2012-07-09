Sequel.require 'adapters/jdbc/transactions'

module Sequel
  module JDBC
    # Database and Dataset support for Derby databases accessed via JDBC.
    module Derby
      # Instance methods for Derby Database objects accessed via JDBC.
      module DatabaseMethods
        PRIMARY_KEY_INDEX_RE = /\Asql\d+\z/i.freeze

        include ::Sequel::JDBC::Transactions

        # Derby doesn't support casting integer to varchar, only integer to char,
        # and char(254) appears to have the widest support (with char(255) failing).
        # This does add a bunch of extra spaces at the end, but those will be trimmed
        # elsewhere.
        def cast_type_literal(type)
          (type == String) ? 'CHAR(254)' : super
        end

        # Derby uses the :derby database type.
        def database_type
          :derby
        end

        # Derby uses an IDENTITY sequence for autoincrementing columns.
        def serial_primary_key_options
          {:primary_key => true, :type => :integer, :identity=>true, :start_with=>1}
        end

        # The SVN version of the database.
        def svn_version
          @svn_version ||= begin
            v = synchronize{|c| c.get_meta_data.get_database_product_version}
            v =~ /\((\d+)\)\z/
            $1.to_i
          end
        end
        
        # Derby supports transaction DDL statements.
        def supports_transactional_ddl?
          true
        end

        private
        
        # Derby optimizes away Sequel's default check of SELECT NULL FROM table,
        # so use a SELECT * FROM table there.
        def _table_exists?(ds)
          ds.first
        end
    
        # Derby-specific syntax for renaming columns and changing a columns type/nullity.
        def alter_table_sql(table, op)
          case op[:op]
          when :rename_column
            "RENAME COLUMN #{quote_schema_table(table)}.#{quote_identifier(op[:name])} TO #{quote_identifier(op[:new_name])}"
          when :set_column_type
            # Derby is very limited in changing a columns type, so adding a new column and then dropping the existing column is
            # the best approach, as mentioned in the Derby documentation.
            temp_name = :x_sequel_temp_column_x
            [alter_table_sql(table, op.merge(:op=>:add_column, :name=>temp_name)),
             from(table).update_sql(temp_name=>::Sequel::SQL::Cast.new(op[:name], op[:type])),
             alter_table_sql(table, op.merge(:op=>:drop_column)),
             alter_table_sql(table, op.merge(:op=>:rename_column, :name=>temp_name, :new_name=>op[:name]))]
          when :set_column_null
            "ALTER TABLE #{quote_schema_table(table)} ALTER COLUMN #{quote_identifier(op[:name])} #{op[:null] ? 'NULL' : 'NOT NULL'}"
          else
            super
          end
        end

        # Derby doesn't allow specifying NULL for columns, only NOT NULL.
        def column_definition_null_sql(sql, column)
          sql << " NOT NULL" if column.fetch(:null, column[:allow_null]) == false
        end
    
        # Add NOT LOGGED for temporary tables to improve performance.
        def create_table_sql(name, generator, options)
          s = super
          s << ' NOT LOGGED' if options[:temp]
          s
        end

        # Insert data from the current table into the new table after
        # creating the table, since it is not possible to do it in one step.
        def create_table_as(name, sql, options)
          super
          from(name).insert(sql.is_a?(Dataset) ? sql : dataset.with_sql(sql))
        end

        # Derby currently only requires WITH NO DATA, with a separate insert
        # to import data.
        def create_table_as_sql(name, sql, options)
          "#{create_table_prefix_sql(name, options)} AS #{sql} WITH NO DATA"
        end

        # Temporary table creation on Derby uses DECLARE instead of CREATE.
        def create_table_prefix_sql(name, options)
          if options[:temp]
            "DECLARE GLOBAL TEMPORARY TABLE #{quote_identifier(name)}"
          else
            super
          end
        end

        # Use IDENTITY_VAL_LOCAL() to get the last inserted id.
        def last_insert_id(conn, opts={})
          statement(conn) do |stmt|
            sql = 'SELECT IDENTITY_VAL_LOCAL() FROM sysibm.sysdummy1'
            rs = log_yield(sql){stmt.executeQuery(sql)}
            rs.next
            rs.getInt(1)
          end
        end

        # Derby uses RENAME TABLE syntax to rename tables.
        def rename_table_sql(name, new_name)
          "RENAME TABLE #{quote_schema_table(name)} TO #{quote_schema_table(new_name)}"
        end

        # Primary key indexes appear to be named sqlNNNN on Derby
        def primary_key_index_re
          PRIMARY_KEY_INDEX_RE
        end

        # Treat clob as string instead of blob
        def schema_column_type(db_type)
          db_type.downcase == 'clob' ? :string : super
        end
        
        # If an :identity option is present in the column, add the necessary IDENTITY SQL.
        def type_literal(column)
          if column[:identity]
            sql = "#{super} GENERATED BY DEFAULT AS IDENTITY"
            if sw = column[:start_with]
              sql << " (START WITH #{sw.to_i}"
              sql << " INCREMENT BY #{column[:increment_by].to_i}" if column[:increment_by]
              sql << ")"
            end
            sql
          else
            super
          end
        end
      end
      
      # Dataset class for Derby datasets accessed via JDBC.
      class Dataset < JDBC::Dataset
        PAREN_CLOSE = Dataset::PAREN_CLOSE
        PAREN_OPEN = Dataset::PAREN_OPEN
        OFFSET = Dataset::OFFSET
        CAST_STRING_OPEN = "RTRIM(".freeze
        BITCOMP_OPEN = "((0 - ".freeze
        BITCOMP_CLOSE = ") - 1)".freeze
        BLOB_OPEN = "CAST(X'".freeze
        BLOB_CLOSE = "' AS BLOB)".freeze
        HSTAR = "H*".freeze
        TIME_FORMAT = "'%H:%M:%S'".freeze
        DEFAULT_FROM = " FROM sysibm.sysdummy1".freeze
        ROWS = " ROWS".freeze
        FETCH_FIRST = " FETCH FIRST ".freeze
        ROWS_ONLY = " ROWS ONLY".freeze
        BOOL_TRUE = '(1 = 1)'.freeze
        BOOL_FALSE = '(1 = 0)'.freeze
        SELECT_CLAUSE_METHODS = clause_methods(:select, %w'select distinct columns from join where group having compounds order limit lock')

        # Derby doesn't support an expression between CASE and WHEN,
        # so emulate it by using an equality statement for all of the
        # conditions.
        def case_expression_sql_append(sql, ce)
          if ce.expression?
            e = ce.expression
            case_expression_sql_append(sql, ::Sequel::SQL::CaseExpression.new(ce.conditions.map{|c, r| [::Sequel::SQL::BooleanExpression.new(:'=', e, c), r]}, ce.default))
          else
            super
          end
        end

        # If the type is String, trim the extra spaces since CHAR is used instead
        # of varchar.  This can cause problems if you are casting a char/varchar to
        # a string and the ending whitespace is important.
        def cast_sql_append(sql, expr, type)
          if type == String
            sql << CAST_STRING_OPEN
            super
            sql << PAREN_CLOSE
          else
            super
          end
        end

        # Handle Derby specific LIKE, extract, and some bitwise compliment support.
        def complex_expression_sql_append(sql, op, args)
          case op
          when :ILIKE
            super(sql, :LIKE, [SQL::Function.new(:upper, args.at(0)), SQL::Function.new(:upper, args.at(1))])
          when :"NOT ILIKE"
            super(sql, :"NOT LIKE", [SQL::Function.new(:upper, args.at(0)), SQL::Function.new(:upper, args.at(1))])
          when :%
            sql << complex_expression_arg_pairs(args){|a, b| "MOD(#{literal(a)}, #{literal(b)})"}
          when :&, :|, :^, :<<, :>>
            raise Error, "Derby doesn't support the #{op} operator"
          when :'B~'
            sql << BITCOMP_OPEN
            literal_append(sql, args.at(0))
            sql << BITCOMP_CLOSE
          when :extract
            sql << args.at(0).to_s << PAREN_OPEN
            literal_append(sql, args.at(1))
            sql << PAREN_CLOSE
          else
            super
          end
        end

        # Derby supports GROUP BY ROLLUP (but not CUBE)
        def supports_group_rollup?
          true
        end

        # Derby does not support IS TRUE.
        def supports_is_true?
          false
        end

        # Derby does not support IN/NOT IN with multiple columns
        def supports_multiple_column_in?
          false
        end

        private

        # Derby needs a hex string casted to BLOB for blobs.
        def literal_blob_append(sql, v)
          sql << BLOB_OPEN << v.unpack(HSTAR).first << BLOB_CLOSE
        end

        # Derby needs the standard workaround to insert all default values into
        # a table with more than one column.
        def insert_supports_empty_values?
          false
        end

        # Derby uses an expression yielding false for false values.
        # Newer versions can use the FALSE literal, but the latest gem version cannot.
        def literal_false
          BOOL_FALSE
        end

        # Derby handles fractional seconds in timestamps, but not in times
        def literal_sqltime(v)
          v.strftime(TIME_FORMAT)
        end

        # Derby uses an expression yielding true for true values.
        # Newer versions can use the TRUE literal, but the latest gem version cannot.
        def literal_true
          BOOL_TRUE
        end

        # Derby doesn't support common table expressions.
        def select_clause_methods
          SELECT_CLAUSE_METHODS
        end

        # Use a default FROM table if the dataset does not contain a FROM table.
        def select_from_sql(sql)
          if @opts[:from]
            super
          else
            sql << DEFAULT_FROM
          end
        end

        # Offset comes before limit in Derby
        def select_limit_sql(sql)
          if o = @opts[:offset]
            sql << OFFSET
            literal_append(sql, o)
            sql << ROWS
          end
          if l = @opts[:limit]
            sql << FETCH_FIRST
            literal_append(sql, l)
            sql << ROWS_ONLY
          end
        end
      end
    end
  end
end
