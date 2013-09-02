module ActsAsTenant
  def self.current_tenant=(tenant)
    RequestStore.store[:current_tenant] = tenant
  end

  def self.current_tenant
    RequestStore.store[:current_tenant]
  end

  def self.with_tenant(tenant, &block)
    if block.nil?
      raise ArgumentError, "block required"
    end

    old_tenant = self.current_tenant
    self.current_tenant = tenant
    value = block.call
    self.current_tenant = old_tenant
    return value
  end

  module ModelExtensions
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      attr_accessor :tenant_association

      def acts_as_tenant(association_name = :account)
        self.tenant_association = reflect_on_association(association_name) || belongs_to(association_name)

        default_scope lambda {
          if ActsAsTenant.configuration.require_tenant && ActsAsTenant.current_tenant.nil?
            raise ActsAsTenant::Errors::NoTenantSet
          end

          if ActsAsTenant.current_tenant
            if self.tenant_association.options[:through]
              table = tenant_association.quoted_table_name
              column = ActiveRecord::Base.connection.quote_column_name(tenant_association.primary_key_column.name)
              joins(tenant_association.name).where("#{table}.#{column} = ?", ActsAsTenant.current_tenant.id)
            else
              where({tenant_association.foreign_key => ActsAsTenant.current_tenant.send(tenant_association.association_primary_key)})
            end
          end
        }

        # Add the following validations to the receiving model:
        # - new instances should have the tenant set
        # - validate that associations belong to the tenant, currently only for belongs_to
        #
        before_validation Proc.new {|m|
          if ActsAsTenant.current_tenant && !self.class.tenant_association.options[:through]
            m.send "#{self.class.tenant_association.foreign_key}=".to_sym, ActsAsTenant.current_tenant.send(self.class.tenant_association.association_primary_key)
          end
        }, :on => :create

        reflect_on_all_associations.each do |a|
          unless a == tenant_association || a.macro != :belongs_to || a.options[:polymorphic]
            validates_each a.foreign_key.to_sym do |record, attr, value|
              record.errors.add attr, "association is invalid [ActsAsTenant]" unless value.nil? || a.klass.where(:id => value).present?
            end
          end
        end

        # Dynamically generate the following methods:
        # - Rewrite the accessors to make tenant immutable
        # - Add a helper method to verify if a model has been scoped by AaT
        #
        define_method "#{tenant_association.foreign_key}=" do |value|
          raise ActsAsTenant::Errors::TenantIsImmutable unless new_record?
          write_attribute("#{self.class.tenant_association.foreign_key}", value)
        end

        define_method "#{tenant_association.name}=" do |model|
          raise ActsAsTenant::Errors::TenantIsImmutable unless new_record?
          super(model)
        end

        def scoped_by_tenant?
          true
        end
      end

      def validates_uniqueness_to_tenant(fields, args ={})
        raise ActsAsTenant::Errors::ModelNotScopedByTenant unless respond_to?(:scoped_by_tenant?)
        tenant_id = lambda { "#{tenant_association.foreign_key}"}.call
        if args[:scope]
          args[:scope] = Array(args[:scope]) << tenant_id
        else
          args[:scope] = tenant_id
        end

        validates_uniqueness_of(fields, args)
      end
    end
  end
end
