require File.dirname(__FILE__) + '/braintree/braintree_common'

begin
  require "braintree"
rescue LoadError
  raise "Could not load the braintree gem.  Use `gem install braintree` to install it."
end

raise "Need braintree gem 2.x.y. Run `gem install braintree --version '~>2.0'` to get the correct version." unless Braintree::Version::Major == 2

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class BraintreeBlueGateway < Gateway
      include BraintreeCommon

      self.display_name = 'Braintree (Blue Platform)'

      def initialize(options = {})
        requires!(options, :merchant_id, :public_key, :private_key)
        @options = options
        @merchant_account_id = options[:merchant_account_id]
        Braintree::Configuration.merchant_id = options[:merchant_id]
        Braintree::Configuration.public_key = options[:public_key]
        Braintree::Configuration.private_key = options[:private_key]
        Braintree::Configuration.environment = (options[:environment] || (test? ? :sandbox : :production)).to_sym
        Braintree::Configuration.logger.level = Logger::ERROR if Braintree::Configuration.logger
        Braintree::Configuration.custom_user_agent = "ActiveMerchant #{ActiveMerchant::VERSION}"
        super
      end

      def authorize(money, credit_card_or_vault_id, options = {})
        create_transaction(:sale, money, credit_card_or_vault_id, options)
      end

      def capture(money, authorization, options = {})
        commit do
          result = Braintree::Transaction.submit_for_settlement(authorization, amount(money).to_s)
          Response.new(result.success?, message_from_result(result))
        end
      end

      def purchase(money, credit_card_or_vault_id, options = {})
        authorize(money, credit_card_or_vault_id, options.merge(:submit_for_settlement => true))
      end

      def credit(money, credit_card_or_vault_id, options = {})
        create_transaction(:credit, money, credit_card_or_vault_id, options)
      end

      def refund(*args)
        # legacy signature: #refund(transaction_id, options = {})
        # new signature: #refund(money, transaction_id, options = {})
        money, transaction_id, options = extract_refund_args(args)
        money = amount(money).to_s if money

        commit do
          result = Braintree::Transaction.refund(transaction_id, money)
          Response.new(result.success?, message_from_result(result),
            {:braintree_transaction => (transaction_hash(result.transaction) if result.success?)},
            {:authorization => (result.transaction.id if result.success?)}
           )
        end
      end

      def void(authorization, options = {})
        commit do
          result = Braintree::Transaction.void(authorization)
          Response.new(result.success?, message_from_result(result),
            {:braintree_transaction => (transaction_hash(result.transaction) if result.success?)},
            {:authorization => (result.transaction.id if result.success?)}
          )
        end
      end

      def store(creditcard, options = {})
        commit do
          result = Braintree::Customer.create(
            :first_name => creditcard.first_name,
            :last_name => creditcard.last_name,
            :email => options[:email],
            :credit_card => {
              :number => creditcard.number,
              :cvv => creditcard.verification_value,
              :expiration_month => creditcard.month.to_s.rjust(2, "0"),
              :expiration_year => creditcard.year.to_s
            }
          )
          Response.new(result.success?, message_from_result(result),
            {
              :braintree_customer => (customer_hash(result.customer) if result.success?),
              :customer_vault_id => (result.customer.id if result.success?)
            }
          )
        end
      end

      def update(vault_id, creditcard, options = {})
        braintree_credit_card = nil
        customer_update_result = commit do
          braintree_credit_card = Braintree::Customer.find(vault_id).credit_cards.detect { |cc| cc.default? }
          return Response.new(false, 'Braintree::NotFoundError') if braintree_credit_card.nil?
          result = Braintree::Customer.update(vault_id,
            :first_name => creditcard.first_name,
            :last_name => creditcard.last_name,
            :email => options[:email]
          )
          Response.new(result.success?, message_from_result(result),
            :braintree_customer => (customer_hash(Braintree::Customer.find(vault_id)) if result.success?)
          )
        end
        return customer_update_result unless customer_update_result.success?
        credit_card_update_result = commit do
          result = Braintree::CreditCard.update(braintree_credit_card.token,
              :number => creditcard.number,
              :expiration_month => creditcard.month.to_s.rjust(2, "0"),
              :expiration_year => creditcard.year.to_s
          )
          Response.new(result.success?, message_from_result(result),
            :braintree_customer => (customer_hash(Braintree::Customer.find(vault_id)) if result.success?)
          )
        end
      end

      def unstore(customer_vault_id)
        commit do
          Braintree::Customer.delete(customer_vault_id)
          Response.new(true, "OK")
        end
      end
      alias_method :delete, :unstore

      private

      def map_address(address)
        return {} if address.nil?
        {
          :street_address => address[:address1],
          :extended_address => address[:address2],
          :company => address[:company],
          :locality => address[:city],
          :region => address[:state],
          :postal_code => address[:zip],
          :country_name => address[:country]
        }
      end

      def commit(&block)
        yield
      rescue Braintree::BraintreeError => ex
        Response.new(false, ex.class.to_s)
      end

      def message_from_result(result)
        if result.success?
          "OK"
        else
          result.errors.map { |e| "#{e.message} (#{e.code})" }.join(" ")
        end
      end

      def create_transaction(transaction_type, money, credit_card_or_vault_id, options)
        transaction_params = create_transaction_parameters(money, credit_card_or_vault_id, options)

        commit do
          result = Braintree::Transaction.send(transaction_type, transaction_params)
          response_params, response_options, avs_result, cvv_result = {}, {}, {}, {}
          if result.success?
            response_params[:braintree_transaction] = transaction_hash(result.transaction)
            response_params[:customer_vault_id] = result.transaction.customer_details.id
            response_options[:authorization] = result.transaction.id
          end
          if result.transaction
            response_options[:avs_result] = {
              :code => nil, :message => nil,
              :street_match => result.transaction.avs_street_address_response_code,
              :postal_match => result.transaction.avs_postal_code_response_code
            }
            response_options[:cvv_result] = result.transaction.cvv_response_code
            if result.transaction.status == "gateway_rejected"
              message = "Transaction declined - gateway rejected"
            else
              message = "#{result.transaction.processor_response_code} #{result.transaction.processor_response_text}"
            end
          else
            message = message_from_result(result)
          end
          response = Response.new(result.success?, message, response_params, response_options)
          response.cvv_result['message'] = ''
          response
        end
      end

      def extract_refund_args(args)
        options = args.extract_options!

        # money, transaction_id, options
        if args.length == 1 # legacy signature
          return nil, args[0], options
        elsif args.length == 2
          return args[0], args[1], options
        else
          raise ArgumentError, "wrong number of arguments (#{args.length} for 2)"
        end
      end

      def customer_hash(customer)
        credit_cards = customer.credit_cards.map do |cc|
          {
            "bin" => cc.bin,
            "expiration_date" => cc.expiration_date
          }
        end

        {
          "email" => customer.email,
          "first_name" => customer.first_name,
          "last_name" => customer.last_name,
          "credit_cards" => credit_cards
        }
      end

      def transaction_hash(transaction)
        if transaction.vault_customer
          vault_customer = {
          }
          vault_customer["credit_cards"] = transaction.vault_customer.credit_cards.map do |cc|
            {
              "bin" => cc.bin
            }
          end
        else
          vault_customer = nil
        end

        customer_details = {
          "id" => transaction.customer_details.id,
          "email" => transaction.customer_details.email
        }

        billing_details = {
          "street_address"   => transaction.billing_details.street_address,
          "extended_address" => transaction.billing_details.extended_address,
          "company"          => transaction.billing_details.company,
          "locality"         => transaction.billing_details.locality,
          "region"           => transaction.billing_details.region,
          "postal_code"      => transaction.billing_details.postal_code,
          "country_name"     => transaction.billing_details.country_name,
        }

        shipping_details = {
          "street_address"   => transaction.shipping_details.street_address,
          "extended_address" => transaction.shipping_details.extended_address,
          "company"          => transaction.shipping_details.company,
          "locality"         => transaction.shipping_details.locality,
          "region"           => transaction.shipping_details.region,
          "postal_code"      => transaction.shipping_details.postal_code,
          "country_name"     => transaction.shipping_details.country_name,
        }

        {
          "order_id"            => transaction.order_id,
          "status"              => transaction.status,
          "customer_details"    => customer_details,
          "billing_details"     => billing_details,
          "shipping_details"    => shipping_details,
          "vault_customer"      => vault_customer,
          "merchant_account_id" => transaction.merchant_account_id
        }
      end

      def create_transaction_parameters(money, credit_card_or_vault_id, options)
        parameters = {
          :amount => amount(money).to_s,
          :order_id => options[:order_id],
          :customer => {
            :id => options[:store] == true ? "" : options[:store],
            :email => options[:email]
          },
          :options => {
            :store_in_vault => options[:store] ? true : false,
            :submit_for_settlement => options[:submit_for_settlement]
          }
        }
        if merchant_account_id = (options[:merchant_account_id] || @merchant_account_id)
          parameters[:merchant_account_id] = merchant_account_id
        end
        if credit_card_or_vault_id.is_a?(String) || credit_card_or_vault_id.is_a?(Integer)
          parameters[:customer_id] = credit_card_or_vault_id
        else
          parameters[:customer].merge!(
            :first_name => credit_card_or_vault_id.first_name,
            :last_name => credit_card_or_vault_id.last_name
          )
          parameters[:credit_card] = {
            :number => credit_card_or_vault_id.number,
            :cvv => credit_card_or_vault_id.verification_value,
            :expiration_month => credit_card_or_vault_id.month.to_s.rjust(2, "0"),
            :expiration_year => credit_card_or_vault_id.year.to_s
          }
        end
        parameters[:billing] = map_address(options[:billing_address]) if options[:billing_address]
        parameters[:shipping] = map_address(options[:shipping_address]) if options[:shipping_address]
        parameters
      end
    end
  end
end

