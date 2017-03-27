module DeepPluck
  class Model
  #---------------------------------------
  #  Initialize
  #---------------------------------------
    def initialize(relation, parent_association_key = nil, parent_model = nil)
      @relation = relation
      @parent_association_key = parent_association_key
      @parent_model = parent_model
      @need_columns = []
      @associations = {}
    end
  #---------------------------------------
  #  Reader
  #---------------------------------------
    def get_reflect(association_key)
      @relation.klass.reflect_on_association(association_key.to_sym) || #add to_sym since rails 3 only support symbol
        raise(ActiveRecord::ConfigurationError, "ActiveRecord::ConfigurationError: Association named '#{association_key}' was not found on #{@relation.klass.name}; perhaps you misspelled it?")
    end
    def with_conditions(reflect, relation)
      options = reflect.options
      relation = relation.instance_exec(&reflect.scope) if reflect.respond_to?(:scope) and reflect.scope
      relation = relation.where(options[:conditions]) if options[:conditions]
      return relation
    end
    def get_join_table(reflect)
      return reflect.options[:through] if reflect.options[:through]
      return (reflect.options[:join_table] || reflect.send(:derive_join_table)) if reflect.macro == :has_and_belongs_to_many
      return nil
    end
    def get_primary_key(reflect)
      return (reflect.belongs_to? ? reflect.klass : reflect.active_record).primary_key
    end
    def get_foreign_key(reflect, reverse: false, with_table_name: false)
      if reverse and (table_name = get_join_table(reflect)) #reverse = parent
        key = reflect.chain.last.foreign_key
      else
        key = (reflect.belongs_to? == reverse ? get_primary_key(reflect) : reflect.foreign_key)
        table_name = (reverse ? reflect.klass : reflect.active_record).table_name
      end
      return "#{table_name}.#{key}" if with_table_name
      return key.to_s #key may be symbol if specify foreign_key in association options
    end
  #---------------------------------------
  #  Contruction OPs
  #---------------------------------------
  private
    def add_need_column(column)
      @need_columns << column.to_s
    end
    def add_association(hash)
      hash.each do |key, value|
        model = (@associations[key] ||= Model.new(get_reflect(key).klass.where(''), key, self))
        model.add(value)
      end
    end
  public
    def add(args)
      return self if args == nil
      args = [args] if not args.is_a?(Array)
      args.each do |arg|
        case arg
        when Hash ; add_association(arg)
        else      ; add_need_column(arg)
        end
      end
      return self
    end
  #---------------------------------------
  #  Load
  #---------------------------------------
  private
    def do_query(parent, reflect, relation)
      parent_key = get_foreign_key(reflect)
      relation_key = get_foreign_key(reflect, reverse: true, with_table_name: true)
      ids = parent.map{|s| s[parent_key]}
      ids.uniq!
      ids.compact!
      relation = with_conditions(reflect, relation)
      return relation.joins(get_join_table(reflect)).where(relation_key => ids)
    end
    def make_parent_hash(parent, primary_key, children_store_name, collection)
      return parent.map{|s| [s[primary_key], s]}.to_h if !collection
      hash = {}
      parent.each do |model_hash|
        key = model_hash[primary_key]
        array = (hash[key] ? hash[key][children_store_name] : []) #share the children if id is duplicated
        model_hash[children_store_name] = array
        hash[key] = model_hash
      end
      return hash
    end
    def assign_values_to_parent(collection, parent, children_hash, children_store_name, foreign_key, reverse: false)
      parent.each{|s|
        next if (id = s[foreign_key]) == nil
        left   =  reverse ? children_hash[id] : s
        right  = !reverse ? children_hash[id] : s
        if collection
          left[children_store_name] << right
        else
          left[children_store_name] = right
        end
      }
    end
    def set_includes_data(parent, children_store_name, model)
      reflect = get_reflect(children_store_name)
      primary_key = get_primary_key(reflect)
      children = model.load_data{|relation| do_query(parent, reflect, relation) }
      if reflect.belongs_to? #Child.where(:id => parent.pluck(:child_id))
        children_hash = make_parent_hash(children, primary_key, children_store_name, reflect.collection?)
        foreign_key = get_foreign_key(reflect)
        assign_values_to_parent(reflect.collection?, parent, children_hash, children_store_name, foreign_key)
      else       #Child.where(:parent_id => parent.pluck(:id))
        parent_hash = make_parent_hash(parent, primary_key, children_store_name, reflect.collection?)
        foreign_key = get_foreign_key(reflect, reverse: true)
        assign_values_to_parent(reflect.collection?, children, parent_hash, children_store_name, foreign_key, reverse: true)
      end
      return children
    end
  public
    def load_data
      prev_need_columns = @parent_model.get_foreign_key(@parent_model.get_reflect(@parent_association_key), reverse: true, with_table_name: true) if @parent_model
      next_need_columns = @associations.map{|key, _| get_foreign_key(get_reflect(key), with_table_name: true) }.uniq
      all_need_columns = [*prev_need_columns, *next_need_columns, *@need_columns].uniq(&Helper::TO_KEY_PROC)
      @relation = yield(@relation) if block_given?
      @data = @relation.pluck_all(*all_need_columns)
      if @data.size != 0
        #for delete_extra_column_data!
        @extra_columns = all_need_columns.map(&Helper::TO_KEY_PROC) - @need_columns.map(&Helper::TO_KEY_PROC)
        @associations.each do |key, model|
          set_includes_data(@data, key, model)
        end
      end
      return @data
    end
    def load_all
      load_data
      delete_extra_column_data!
      return @data
    end
    def delete_extra_column_data!
      return if @data.blank?
      @data.each{|s| s.except!(*@extra_columns) }
      @associations.each{|_, model| model.delete_extra_column_data! }
    end
  #---------------------------------------
  #  Helper methods
  #---------------------------------------
    module Helper
      TO_KEY_PROC = proc{|s| Helper.column_to_key(s) }
      def self.column_to_key(key) #user_achievements.user_id => user_id
        key = key[/(\w+)[^\w]*\z/]
        key.gsub!(/[^\w]+/, '')
        return key
      end
    end
  end
end
