require "data_tables/data_tables_helper"

module DataTablesController
  def self.included(cls)
    cls.extend(ClassMethods)
  end

  module ClassMethods
    def datatables_source(action, model,  *attrs)
      modelCls = Kernel.const_get(model.to_s.split("_").collect(&:capitalize).join)
      modelAttrs = nil
      if modelCls < Ohm::Model
        if Gem.loaded_specs['ohm'].version == Gem::Version.create('0.1.5')
          modelAttrs = Hash[*modelCls.new.attributes.collect { |v| [v.to_s, nil] }.flatten]
        else
          modelAttrs = {}
        end
      else
        modelAttrs = modelCls.new.attributes
      end
      columns = []
      modelAttrs.each_key { |k| columns << k }

      options = {}
      attrs.each do |option|
        option.each { |k,v| options[k] = v }
      end

      # override columns
      columns = options_to_columns(options) if options[:columns]

      # define columns so they are accessible from the helper
      define_columns(modelCls, columns, action)

      # define method that returns the data for the table
      define_datatables_action(self, action, modelCls, columns, options)
    end

    # named_scope is a combination table that include everything shown in UI.
    # except is the codition used for Ohm's except method, it should be key-value format,
    # such as [['name', 'bluesocket'],['id','1']].
    def define_datatables_action(controller, action, modelCls, columns, options = {})
      conditions = options[:conditions] || []
      scope = options[:scope] || :domain
      named_scope = options[:named_scope]
      named_scope_args = options[:named_scope_args]
      except = options[:except] || []
      es_block = options[:es_block]
      order_sort = options[:order_sort]

      #
      # ------- Ohm ----------- #
      #
      if modelCls < Ohm::Model
        define_method action.to_sym do
          logger.debug "[tire] (datatable:#{__LINE__}) #{action.to_sym} #{modelCls} < Ohm::Model"

          if scope == :domain
            domain = ActiveRecord::Base.connection.schema_search_path.to_s.split(",")[0]
            return if domain.nil?
          end
          search_condition = params[:sSearch].blank? ? nil : params[:sSearch].to_s

          sort_column = params[:iSortCol_0].to_i
          current_page = (params[:iDisplayStart].to_i/params[:iDisplayLength].to_i rescue 0) + 1
          per_page = params[:iDisplayLength] || 10
          per_page = per_page.to_i
          sort_dir = params[:sSortDir_0] || 'desc'
          column_name_sym = columns[sort_column][:name].to_sym

          objects = []
          total_display_records = 0
          total_records = 0

          if defined? Tire
            #
            # ----------- Elasticsearch/Tire for Ohm ----------- #
            #
            elastic_index_name = "#{Tire::Model::Search.index_prefix}#{modelCls.to_s.underscore}"
            logger.debug "*** (datatable:#{__LINE__}) Using tire for search #{modelCls} (#{elastic_index_name})"

            retried = 0
            if Tire.index(elastic_index_name){exists?}.response.code != 404
              begin
                controller_instance = self
                results = Tire.search(elastic_index_name) do
                  query do
                    boolean do
                      if search_condition && retried < 2
                        must { match :_all, search_condition, type: 'phrase_prefix' }
                      else
                        must { all }
                      end

                      except.each do |expt|
                        must_not { match expt[0].to_sym, expt[1].to_s }
                      end
                    end
                  end

                  # retry #1 exclude sorting from search query
                  sort{ by column_name_sym, sort_dir } if retried < 1

                  filter(:term, domain: domain) unless domain.blank?
                  if es_block.is_a?(Symbol)
                    controller_instance.send(es_block, self)
                  else
                    es_block.call(self) if es_block.respond_to?(:call)
                  end
                  from (current_page-1) * per_page
                  size per_page
                end.results

                objects = results.map{ |r| modelCls[r._id] }.compact
                total_display_records = results.total

                total_records = Tire.search(elastic_index_name, search_type: 'count') do
                  query do
                    boolean do
                      must { all }
                      except.each do |expt|
                        must_not { match expt[0].to_sym, expt[1].to_s }
                      end
                    end
                  end
                  filter(:term, domain: domain) unless domain.blank?
                  es_block.call(self) if es_block.respond_to?(:call)
                end.results.total
              rescue Tire::Search::SearchRequestFailed => e
                if retried < 2
                  retried += 1
                  logger.info "Will retry(#{retried}) again because #{e.inspect}"
                  retry
                end
                logger.info "*** ERROR: Tire::Search::SearchRequestFailed => #{e.inspect}"
              end
            else
              logger.debug "Index #{elastic_index_name} does not exists yet in ES."
            end
          else
            #
            # -------- Redis/Lunar search --------------- #
            #
            logger.debug "*** (datatable:#{__LINE__}) Using Redis/Lunar for search #{modelCls} (#{elastic_index_name})"
            records = scope == :domain ? modelCls.find(:domain => domain) : modelCls.all
            if except
              except.each do |f|
                records = records.except(f[0].to_sym => f[1])
              end
            end
            total_records = records.size

            logger.debug "*** (datatable:#{__LINE__}) NOT using tire for search"
            options = {}
            domain_id = domain.split("_")[1].to_i if scope == :domain
            options[:domain] = domain_id .. domain_id if scope == :domain
            options[:fuzzy] = {columns[sort_column][:name].to_sym => search_condition}
            objects = Lunar.search(modelCls, options)
            total_display_records = objects.size
            if Gem.loaded_specs['ohm'].version == Gem::Version.create('0.1.5')
              objects = objects.sort(:by => columns[sort_column][:name].to_sym,
                                     :order => "ALPHA " + params[:sSortDir_0].capitalize,
                                     :start => params[:iDisplayStart].to_i,
                                     :limit => params[:iDisplayLength].to_i)
            else
              objects = objects.sort(:by => columns[sort_column][:name].to_sym,
                                     :order => "ALPHA " + params[:sSortDir_0].capitalize,
                                     :limit => [params[:iDisplayStart].to_i, params[:iDisplayLength].to_i])
            end
            # -------- Redis/Lunar search --------------- #
          end

          data = objects.collect do |instance|
            columns.collect { |column| datatables_instance_get_value(instance, column) }
          end
          render :text => {:iTotalRecords => total_records,
            :iTotalDisplayRecords => total_display_records,
            :aaData => data,
            :sEcho => params[:sEcho].to_i}.to_json
        end
      # ------- /Ohm ----------- #
      else # Non-ohm models
        # add_search_option will determine whether the search text is empty or not
        init_conditions = conditions.clone
        add_search_option = false

        if modelCls.ancestors.any?{|ancestor| ancestor.name == "Tire::Model::Search"}
          #
          # ------- Elasticsearch ----------- #
          #
          define_method action.to_sym do
            domain_name = ActiveRecord::Base.connection.schema_search_path.to_s.split(",")[0]
            logger.debug "*** (datatables:#{__LINE__}) Using ElasticSearch for #{modelCls.name}"
            objects =  []

            condstr = nil
            starttime_str = nil
            endtime_str = nil
            unless params[:sSearch].blank?
              sort_column_id = params[:iSortCol_0].to_i
              sort_column = columns[sort_column_id]
              if sort_column && sort_column.has_key?(:attribute)
                condstr = params[:sSearch].gsub(/_/, '\\\\_').gsub(/%/, '\\\\%')
              end
            end
            unless params[:sStarttime].blank? || params[:sEndtime].blank?
              sort_column_id = params[:iSortCol_0].to_i
              sort_column = columns[sort_column_id]
              if sort_column && sort_column.has_key?(:attribute)
                starttime = params[:sStarttime]
                endtime = params[:sEndtime]
              end
            end
            
            sort_column = params[:iSortCol_0].to_i
            current_page = (params[:iDisplayStart].to_i/params[:iDisplayLength].to_i rescue 0)+1
            per_page = params[:iDisplayLength] || 10
            column_name = columns[sort_column][:name] || 'message'
            sort_dir = params[:sSortDir_0] || 'desc'

            begin
              query = Proc.new do
                query do
                  boolean do
                    if condstr
                      must { match :_all, condstr, type: 'phrase_prefix' }          
                    else
                      must { all }
                    end
                    except.each do |expt|
                      must_not { match expt[0].to_sym, expt[1].to_s }
                    end
                  end
                end
                filter(:range, created_at: {gte: starttime,lte: endtime}) unless starttime.blank? || endtime.blank?
                filter(:term, domain: domain_name) unless domain_name.blank?
                es_block.call(self) if es_block.respond_to?(:call)
              end

              results = modelCls.search(page: current_page,
                                        per_page: per_page,
                                        sort: "#{column_name}:#{sort_dir}",
                                        &query)
              objects = results.to_a
              total_display_records = results.total
              total_records = modelCls.search(search_type: 'count') do
                filter(:term, domain: domain_name) unless domain_name.blank?
                es_block.call(self) if es_block.respond_to?(:call)
              end.total
            rescue Tire::Search::SearchRequestFailed => e
              logger.debug "[Tire::Search::SearchRequestFailed] #{e.inspect}\n#{e.backtrace.join("\n")}"
              objects = []
              total_display_records = 0
              total_records = 0
            end

            data = objects.collect do |instance|
              columns.collect { |column| datatables_instance_get_value(instance, column) }
            end

            render :text => {:iTotalRecords => total_records,
              :iTotalDisplayRecords => total_display_records,
              :aaData => data,
              :sEcho => params[:sEcho].to_i}.to_json
          end
          # ------- /Elasticsearch ----------- #
        else
          #
          # ------- Postgres ----------- #
          #
          logger.debug "(datatable) #{action.to_sym} #{modelCls} < ActiveRecord"

          define_method action.to_sym do
            condition_local = ''
            condition = ''

            unless params[:sSearch].blank?
              sort_column_id = params[:iSortCol_0].to_i
              sort_column = columns[sort_column_id]
              condstr = params[:sSearch].strip.gsub(/%/, '%%').gsub(/'/,"''")

              search_columns = options[:columns].map{|e| e.class == Symbol ? e : e[:attribute] }.compact
              condition = search_columns.map do |column_name|
                " ((text(#{column_name}) ILIKE '%#{condstr}%')) "
              end.compact.join(" OR ")
              condition = "(#{condition})" unless condition.blank?
            end
            unless params[:sStarttime].blank? || params[:sEndtime].blank?
              sort_column_id = params[:iSortCol_0].to_i
              sort_column = columns[sort_column_id]
              if sort_column && sort_column.has_key?(:attribute)
                starttime = params[:sStarttime]
                endtime = params[:sEndtime]
              end
              condition = condition + "AND" unless condition.blank?
              condition = condition + "(last_seen BETWEEN  '#{starttime}' AND '#{endtime}') " 
            end
            condition_local = "(#{condition})" unless condition.blank?

            # We just need one conditions string for search at a time.  Every time we input
            # something else in the search bar we will pop the previous search condition
            # string and push the new string.
            if condition_local != ''
              if add_search_option == false
                conditions << condition_local
                add_search_option = true
              else
                if conditions != []
                  conditions.pop
                  conditions << condition_local
                end
              end
            else
              if add_search_option == true
                if conditions != []
                  conditions.pop
                  add_search_option = false
                end
              end
            end

            if named_scope
              args = named_scope_args ? Array(self.send(named_scope_args)) : []
              total_records = modelCls.send(named_scope, *args).count :conditions => init_conditions.join(" AND ")
              total_display_records = modelCls.send(named_scope, *args).count :conditions => conditions.join(" AND ")
            else
              total_records = modelCls.count :conditions => init_conditions.join(" AND ")
              total_display_records = modelCls.count :conditions => conditions.join(" AND ")
            end
            sort_column = params[:iSortCol_0].to_i
            current_page = (params[:iDisplayStart].to_i/params[:iDisplayLength].to_i rescue 0)+1
            order = if order_sort.respond_to?(:call)
                      order_sort.call(columns[sort_column][:name], params[:sSortDir_0])
                    else
                      "#{columns[sort_column][:name]} #{params[:sSortDir_0]}"
                    end

            if named_scope
                objects = modelCls.send(named_scope, *args).paginate(:page => current_page,
                                            :order => "#{order}",
                                            :conditions => conditions.join(" AND "),
                                            :per_page => params[:iDisplayLength])
            else
                objects = modelCls.paginate(:page => current_page,
                                            :order => order,
                                            :conditions => conditions.join(" AND "),
                                            :per_page => params[:iDisplayLength])
            end
            data = objects.collect do |instance|
              columns.collect { |column| datatables_instance_get_value(instance, column) }
            end
            render :text => {:iTotalRecords => total_records,
              :iTotalDisplayRecords => total_display_records,
              :aaData => data,
              :sEcho => params[:sEcho].to_i}.to_json
            #
            # ------- /Postgres ----------- #
            #
          end
        end
      end
    end

    private

    #
    # Takes a list of columns from options and transforms them
    #
    def options_to_columns(options)
      columns = []
      options[:columns].each do |column|
        if column.kind_of? Symbol # a column from the database, we don't need to do anything
          columns << {:name => column, :attribute => column}
        elsif column.kind_of? Hash
    col_hash = { :name => column[:name], :special => column }
          col_hash[:attribute] = column[:attribute] if column[:attribute]
          columns << col_hash
        end
      end
      columns
    end

    def define_columns(cls, columns, action)
      define_method "datatable_#{action}_columns".to_sym do
        columnNames = {}
        columns.each do |column|
          columnName = ''
          if column[:method] or column[:eval]
            columnName << I18n.t(column[:name], :default => column[:name].to_s)
          else
            columnName << I18n.t(column[:name].to_sym, :default => column[:name].to_s)
          end
          columnName << ' *' unless column.has_key?(:attribute)
          columnNames[columnName] = column.has_key?(:attribute) ? true : false
        end

        columnNames
      end
    end
  end

  # gets the value for a column and row
  def datatables_instance_get_value(instance, column)
    if column[:special]
      get_instance_special_value(instance, column[:special])
    elsif column[:attribute]
      begin
      get_instance_value(instance.send("#{column[:attribute]}"))
      rescue ArgumentError => error
        handle_argument_error(error, instance, column)
      end
    else
      return "value not found"
    end
  end

  def get_instance_special_value(instance, special)
    if special[:method]
      return method(special[:method].to_sym).call(instance)
    elsif special[:eval]
      proc = lambda { obj = instance; binding }
      return Kernel.eval(special[:eval], proc.call)
    end
  end

  def get_instance_value(value)
    if !value.blank? || value == false
      trans = I18n.t(value.to_s.to_sym, :default => value.to_s)
      return trans.class == String ? trans : value.to_s
    else
      return ''
    end
  end

  def handle_argument_error(error, instance, column)
    if error.message.include? "UTF-8"
      invalid_sequence = instance.send("#{column[:attribute]}").bytes.to_a
      logger.warn("[datatables] Error: #{instance.class.name} for "+
                  "id #{instance.id}, column #{column[:attribute]}: " +
                  "Invalid UTF8 sequence is [#{invalid_sequence.join(", ")}]")
      return ''
    else
      raise
    end
  end

  def datatable_source(name)
    {:action => name, :attrs => method("datatable_#{name}_columns".to_sym).call}
  end
end
