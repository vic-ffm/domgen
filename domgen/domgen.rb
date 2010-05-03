require 'yaml'
require 'erb'
require 'fileutils'

# banner in sql generation
def banner(title)
  <<SQL
--
-- #{title}
--
SQL
end

# clean up string so it can be a sql identifier
def s(string)
  string.to_s.gsub('[].:', '')
end

# quote string using database rules
def q(string)
  "[#{string.to_s}]"
end

def pluralize(string)
  "#{string}s"
end

def underscore(camel_cased_word)
  camel_cased_word.to_s.gsub(/::/, '/').
          gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').
          gsub(/([a-z\d])([A-Z])/, '\1_\2').
          tr("-", "_").
          downcase
end

def java_accessors(name,type)
  <<JAVA
  public #{type} get#{name}()
  {
     return #{name};
  }

  public void set#{name}( final #{type} value )
  {
     #{name} = value;
  }
JAVA
end

module Domgen
  class BaseConfigElement
    def initialize(options = {})
      options.each_pair do |k, v|
        self.send "#{k}=", v
      end
      yield self if block_given?
    end
  end

  class Constraint < BaseConfigElement
    attr_reader :name
    attr_accessor :sql

    def initialize(name, options = {}, &block)
      @name = name
      super(options, &block)
    end
  end

  class Query < BaseConfigElement
    attr_reader :object_type
    attr_reader :name
    attr_accessor :jpql
    attr_accessor :parameter_types

    def initialize(object_type, name, jpql, options = {}, &block)
      @object_type = object_type
      @name = name
      @jpql = jpql
      super(options, &block)
    end

    def populate_parameters
      @parameter_types = {} unless @parameter_types
      parameters.each do |p|
        if @parameter_types[p].nil?
          attribute = object_type.attribute_by_name(p)
          raise "Unknown parameter type for #{p}" unless attribute
          @parameter_types[p] = attribute.java.java_type
        end
      end
    end

    def parameters
       return [] if jpql.nil?
       jpql.scan(/:[^\W]+/).collect {|s| s[1..-1]}
    end

    def fully_qualified_name
      if singular?
        type_spec = object_type.name
      else
        type_spec = pluralize(object_type.name)
      end
      "#{name_prefix}#{type_spec}#{name_suffix}"
    end

    def local_name
      "#{name_prefix}#{name_suffix}"
    end

    def name_prefix
      "find#{singular? ? '' : 'All'}"
    end

    def name_suffix
      jpql.nil? ? '' : "By#{name}"
    end


    attr_writer :query_type

    def query_type
      @query_type = :selector if @query_type.nil?
      @query_type
    end

    attr_writer :singular

    def singular?
      @singular = false if @singular.nil?
      @singular
    end

    def query_string
      if query_type == :full
        query = jpql
      elsif query_type == :selector
        query = "SELECT O FROM #{object_type.name} O #{jpql.nil? ? '' : "WHERE "}#{jpql}"
      else
        raise "Unknown query type #{query_type}"
      end
      query.gsub("\n",' ')
    end
  end

  class AttributeSetConstraint < BaseConfigElement
    attr_reader :name
    attr_accessor :attribute_names

    def initialize(name, attribute_names, options, &block)
      @name, @attribute_names = name, attribute_names
      super(options, &block)
    end
  end

  class Validation < BaseConfigElement
    attr_reader :name
    attr_accessor :sql

    def initialize(name, options = {}, &block)
      @name = name
      super(options, &block)
    end
  end

  class Attribute < BaseConfigElement
    attr_reader :object_type
    attr_reader :name
    attr_reader :attribute_type

    def initialize(object_type, name, attribute_type, options = {}, &block)
      @object_type = object_type
      @name = name
      @attribute_type = attribute_type
      super(options, &block)
      raise "Invalid type #{attribute_type} for persistent attribute #{name}" if persistent? && !self.class.persistent_types.include?(attribute_type)
    end

    def reference?
      self.attribute_type == :reference
    end

    attr_writer :validate

    def validate?
      @validate = true if @validate.nil?
      @validate
    end

    attr_writer :unique

    def unique?
      @unique = false if @unique.nil?
      @unique
    end

    attr_writer :primary_key

    def primary_key?
      @primary_key = false if @primary_key.nil?
      @primary_key
    end

    attr_reader :length

    def length=(length)
      raise "length on #{name} is invalid as attribute is not a string" unless self.attribute_type == :string
      @length = length
    end

    attr_writer :unique

    def unique?
      @unique = false if @unique.nil?
      @unique
    end

    attr_writer :nullable

    def nullable?
      @nullable = false if @nullable.nil?
      @nullable
    end

    attr_reader :values

    def values=(values)
      raise "values on #{name} is invalid as attribute is not an i_enum" unless self.attribute_type == :i_enum
      @values = values
    end

    attr_writer :immutable

    def immutable?
      @immutable = false if @immutable.nil?
      @immutable
    end

    attr_writer :persistent

    def persistent?
      @persistent = true if @persistent.nil?
      @persistent
    end

    attr_reader :references

    def references=(references)
      raise "references on #{name} is invalid as attribute is not a reference" unless reference?
      @references = references
    end

    def referenced_object
      raise "referenced_object on #{name} is invalid as attribute is not a reference" unless reference?
      self.object_type.schema.object_type_by_name(self.references)
    end

    attr_writer :inverse_relationship_type

    def inverse_relationship_type
      raise "inverse_relationship_type on #{name} is invalid as attribute is not a reference" unless reference?
      @inverse_relationship_type = :has_many if @inverse_relationship_type.nil?
      @inverse_relationship_type
    end

    attr_writer :inverse_relationship_name

    def inverse_relationship_name
      raise "inverse_relationship_name on #{name} is invalid as attribute is not a reference" unless reference?
      @inverse_relationship_name = object_type.name if @inverse_relationship_name.nil?
      @inverse_relationship_name
    end

    def self.persistent_types
      [:text, :string, :reference, :boolean, :integer, :i_enum]
    end
  end

  class ObjectType
    attr_reader :schema
    attr_reader :name
    attr_reader :options
    attr_reader :attributes
    attr_reader :constraints
    attr_reader :validations
    attr_reader :queries
    attr_reader :codependent_constraints
    attr_reader :incompatible_constraints
    attr_reader :referencing_attributes

    def initialize(schema, name, options = {})
      @schema, @name = schema, name
      @options = options
      @attributes = []
      @constraints = []
      @validations = []
      @codependent_constraints = []
      @incompatible_constraints = []
      @queries = []
      @referencing_attributes = []
      yield self if block_given?
      self.query('All', nil, :singular => false)
      self.query(primary_key.name,
                 "#{primary_key.java.field_name} = :#{primary_key.java.field_name}",
                 :singular => true)
      queries.each do |q|
        q.populate_parameters
      end
      sql.verify
    end

    def object_type
      self
    end

    def boolean(name, options = {}, &block)
      attribute(name, :boolean, options, &block)
    end

    def text(name, options = {}, &block)
      attribute(name, :text, options, &block)
    end

    def string(name, length, options = {}, &block)
      attribute(name, :string, options.merge({:length => length}), &block)
    end

    def integer(name, options = {}, &block)
      attribute(name, :integer, options, &block)
    end

    def reference(other_type, options = {}, &block)
      name = (options.delete(:name) || other_type).to_s.to_sym
      attribute(name, :reference, options.merge({:references => other_type}), &block)
    end

    def i_enum(name, values, options = {}, &block)
      values.each_pair do |k, v|
        raise "Key #{k} of i_enum #{name} should be a string" unless k.instance_of?(String)
        raise "Value #{v} for key #{k} of i_enum #{name} should be an integer" unless v.instance_of?(Fixnum)
      end
      attribute(name, :i_enum, options.merge({:values => values}), &block)
    end

    def attribute(name, type, options = {}, &block)
      attribute = Attribute.new(self, name, type, options, &block)
      @attributes << attribute
      attribute
    end

    def constraint(name, options = {}, &block)
      constraint = Constraint.new(name, options, &block)
      @constraints << constraint
      constraint
    end

    def validation(name, options = {}, &block)
      validation = Validation.new(name, options, &block)
      @validations << validation
      validation
    end

    def codependent_constraint(name, attribute_names, options = {}, &block)
      codependent_constraint = AttributeSetConstraint.new(name, attribute_names, options, &block)
      @codependent_constraints << codependent_constraint
      codependent_constraint
    end

    def incompatible_constraint(name, attribute_names, options = {}, &block)
      incompatible_constraint = AttributeSetConstraint.new(name, attribute_names, options, &block)
      @incompatible_constraints << incompatible_constraint
      incompatible_constraint
    end

    def query(name, jpql, options = {}, &block)
      query = Query.new(self, name, jpql, options, &block)
      @queries << query
      query
    end

    # Assume single column pk
    def primary_key
      attributes.find {|a| a.primary_key? }
    end

    def attribute_by_name(name)
      attributes.find{|a| a.name.to_s == name.to_s}
    end
  end

  class Schema < BaseConfigElement
    attr_reader :schema_set
    attr_reader :name
    attr_reader :object_types

    def initialize(schema_set, name, options = {}, &block)
      @schema_set = schema_set
      @name = name
      @object_types = []
      super(options, &block)
    end

    def schema
      self
    end

    def define_object_type(name, options = {}, &block)
      @object_types << ObjectType.new(self, name, options, &block)
    end

    def object_type_by_name(name)
      object_type = @object_types.find{|o|o.name.to_s == name.to_s}
      raise "Unable to locate object_type #{name}" unless object_type
      object_type
    end
  end

  class SchemaSet < BaseConfigElement
    attr_reader :schemas

    def initialize(options = {}, &block)
      @schemas = []
      super(options, &block)
      self.schemas.each do |schema|
        schema.object_types.each do |object_type|
          object_type.attributes.each do |attribute|
            if attribute.reference?
              attribute.referenced_object.referencing_attributes << attribute
            end
          end
        end
      end
    end

    def schema_set
      self
    end

    def define_schema(name, options = {}, &block)
      @schemas << Domgen::Schema.new(self, name, options, &block)
    end
  end

  module Generator
    class TemplateSet
      attr_accessor :per_schema_set
      attr_accessor :per_schema
      attr_accessor :per_object_type

      def initialize
        self.per_schema_set = []
        self.per_schema = []
        self.per_object_type = []
      end

      def self.create(elements = nil)
        elements = [:jpa, :active_record, :sql] unless elements
        ts = TemplateSet.new
        if elements.include?(:jpa)
          ts.per_schema_set << TemplateMap.new('jpa/persistence', 'META-INF/persistence.xml', 'resources')
          ts.per_schema << TemplateMap.new('jpa/entity_manager',
                                           '#{schema.java.package.gsub(".","/")}/SchemaEntityManager.java',
                                           'java')
          ts.per_object_type << TemplateMap.new('jpa/model',
                                                '#{object_type.java.fully_qualified_name.gsub(".","/")}.java',
                                                'java')
          ts.per_object_type << TemplateMap.new('jpa/dao',
                                                '#{object_type.java.fully_qualified_name.gsub(".","/")}DAO.java',
                                                'java')
        end
        if elements.include?(:sql)
          ts.per_schema << TemplateMap.new('sql/ddl', 'schema.sql', 'databases/#{schema.name}')
          ts.per_schema << TemplateMap.new('sql/constraints', '#{schema.name}_constraints.sql', 'databases/#{schema.name}')
        end
        if elements.include?(:active_record)
          ts.per_object_type << TemplateMap.new('ar/model', '#{object_type.ruby.filename}.rb', 'ruby')
        end
        ts
      end

      def generate_artifacts(schema_set, directory)
        self.per_schema_set.each do |template_map|
          template_map.generate(directory, schema_set)
        end

        self.per_schema.each do |template_map|
          schema_set.schemas.each do |schema|
            template_map.generate(directory, schema)
          end
        end

        self.per_object_type.each do |template_map|
          schema_set.schemas.each do |schema|
            schema.object_types.each do |object_type|
              template_map.generate(directory, object_type)
            end
          end
        end
      end
    end

    class TemplateMap
      attr_reader :template_name
      attr_reader :output_filename_pattern
      attr_reader :basedir

      def initialize(template_name, output_filename_pattern, basedir)
        @template_name, @output_filename_pattern, @basedir = template_name, output_filename_pattern, basedir
      end

      def generate(basedir, context)
        context_binding = context.send :binding
        output_filename = eval("\"#{output_filename_pattern}\"", context_binding)
        output_dir = eval("\"#{self.basedir}\"", context_binding)
        output_filename = File.join(basedir, output_dir, output_filename)
        result = template.result(context_binding)
        FileUtils.mkdir_p File.dirname(output_filename)
        File.open(output_filename, 'w') do |f|
          f.write(result)
        end
      end

      protected

      def template
        unless @template
          filename = "#{File.dirname(__FILE__)}/templates/#{template_name}.erb"
          @template = ERB.new(IO.read(filename))
        end
        @template
      end
    end
  end
end

require "#{File.dirname(__FILE__)}/java_model_ext.rb"
require "#{File.dirname(__FILE__)}/ruby_model_ext.rb"
require "#{File.dirname(__FILE__)}/sql_model_ext.rb"
