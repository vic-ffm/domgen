def generate(repository)
  application = Domgen::Naming.underscore(repository.name)
  constant_prefix = Domgen::Naming.uppercase_constantize(repository.name)

  data = {}

  data['environment_vars'] = {}

  if repository.jms?
    data['jms_resources'] = {}

    destinations = {}

    repository.jms.endpoint_methods.each do |method|
      destinations[method.jms.destination_resource_name] = {'type' => method.jms.destination_type, 'physical_name' => method.jms.physical_resource_name}
    end
    repository.jms.router_methods.each do |method|
      destinations[method.jms.route_to_destination_resource_name] =
        {'type' => method.jms.route_to_destination_type, 'physical_name' => method.jms.route_to_physical_resource_name}
    end

    destinations.each_pair do |name, config|
      data['jms_resources'][name] = {'restype' => config['type'], 'properties' => {'Name' => config['physical_name']}}
    end

    data['environment_vars']["#{constant_prefix}_BROKER_USERNAME"] = repository.jms.default_username
    data['environment_vars']["#{constant_prefix}_BROKER_PASSWORD"] = ''

    data['jms_resources'][repository.jms.connection_factory_resource_name] =
      {
        'restype' => 'javax.jms.ConnectionFactory',
        'properties' => {
          'UserName' => "${#{constant_prefix}_BROKER_USERNAME}",
          'Password' => "${#{constant_prefix}_BROKER_PASSWORD}"
        }
      }
  end

  if repository.jpa?
    units = []
    if repository.jpa.include_default_unit? && repository.jpa.standalone?
      units << repository.jpa.default_persistence_unit
    end
    units += repository.jpa.standalone_persistence_units

    data['jdbc_connection_pools'] = {}
    units.each do |unit|
      name = unit.short_name
      cname = Domgen::Naming.uppercase_constantize(name)
      resource = unit.data_source
      connection_pool = "#{resource}ConnectionPool"

      data['jdbc_connection_pools'][connection_pool] = {}
      data['jdbc_connection_pools'][connection_pool]['datasourceclassname'] =
        repository.mssql? ? 'net.sourceforge.jtds.jdbcx.JtdsDataSource' :
          repository.pgsql? ? 'org.postgresql.ds.PGSimpleDataSource' :
            nil
      data['jdbc_connection_pools'][connection_pool]['restype'] =
        unit.xa_data_source? ? 'javax.sql.XADataSource' : 'javax.sql.DataSource'
      data['jdbc_connection_pools'][connection_pool]['isconnectvalidatereq'] = 'true'
      data['jdbc_connection_pools'][connection_pool]['validationmethod'] = 'auto-commit'
      data['jdbc_connection_pools'][connection_pool]['ping'] = 'true'
      data['jdbc_connection_pools'][connection_pool]['description'] = "#{name} connection pool for application #{application}"

      data['jdbc_connection_pools'][connection_pool]['properties'] = {}

      data['jdbc_connection_pools'][connection_pool]['resources'] = {}
      data['jdbc_connection_pools'][connection_pool]['resources'][resource] = {}
      data['jdbc_connection_pools'][connection_pool]['resources'][resource]['description'] = "#{name} resource for application #{application}"

      data['environment_vars']["#{constant_prefix}_#{cname}_DB_HOST"] = nil
      data['environment_vars']["#{constant_prefix}_#{cname}_DB_PORT"] = repository.mssql? ? 1433 : repository.pgsql? ? 5432 : nil
      data['environment_vars']["#{constant_prefix}_#{cname}_DB_DATABASE"] = nil
      data['environment_vars']["#{constant_prefix}_#{cname}_DB_USERNAME"] = repository.jpa.default_username
      data['environment_vars']["#{constant_prefix}_#{cname}_DB_PASSWORD"] = nil

      data['jdbc_connection_pools'][connection_pool]['properties']['ServerName'] = "${#{constant_prefix}_#{cname}_DB_HOST}"
      data['jdbc_connection_pools'][connection_pool]['properties']['User'] = "${#{constant_prefix}_#{cname}_DB_USERNAME}"
      data['jdbc_connection_pools'][connection_pool]['properties']['Password'] = "${#{constant_prefix}_#{cname}_DB_PASSWORD}"
      data['jdbc_connection_pools'][connection_pool]['properties']['PortNumber'] = "${#{constant_prefix}_#{cname}_DB_PORT}"
      data['jdbc_connection_pools'][connection_pool]['properties']['DatabaseName'] = "${#{constant_prefix}_#{cname}_DB_DATABASE}"

      if repository.mssql?
        data['environment_vars']["#{constant_prefix}_#{cname}_DB_INSTANCE"] = nil
        data['jdbc_connection_pools'][connection_pool]['properties']['Instance'] = "${#{constant_prefix}_#{cname}_DB_INSTANCE}"

        # Standard DataSource configuration
        data['jdbc_connection_pools'][connection_pool]['properties']['AppName'] = application
        data['jdbc_connection_pools'][connection_pool]['properties']['ProgName'] = 'GlassFish'
        data['jdbc_connection_pools'][connection_pool]['properties']['SocketTimeout'] = unit.socket_timeout
        data['jdbc_connection_pools'][connection_pool]['properties']['LoginTimeout'] = unit.login_timeout
        data['jdbc_connection_pools'][connection_pool]['properties']['SocketKeepAlive'] = 'true'

        # This next lines is required for jtds drivers as still old driver style
        data['jdbc_connection_pools'][connection_pool]['properties']['jdbc30DataSource'] = 'true'
      end
    end
  end

  ::JSON.pretty_generate(data)
end
