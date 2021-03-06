module PaypalService::API
  PaypalAccountStore = PaypalService::Store::PaypalAccount

  class Accounts

    def initialize(permissions, merchant, logger = PaypalService::Logger.new)
      @permissions = permissions
      @merchant = merchant
      @logger = logger
    end

    # The API implmenetation
    #

    ## POST /accounts/request

    def request(body:)
      with_success_permissions(
        PaypalService::DataTypes::Permissions
        .create_req_perm({callback: body[:callback_url] })
      ) { |perm_req_response|
        account = PaypalAccountStore.create(
          opts: {
            community_id: body[:community_id],
            person_id: body[:person_id],
            order_permission_request_token: perm_req_response[:request_token],
            order_permission_paypal_username_to: perm_req_response[:username_to]
          })

        redirect_url = URLUtils.prepend_path_component(perm_req_response[:redirect_url], body[:country])

        Result::Success.new(
          DataTypes.create_account_request(
          {
            community_id: body[:community_id],
            person_id: body[:person_id],
            redirect_url: redirect_url
          }))
      }
    end

    ## POST /accounts/create?community_id=1&person_id=asdgaretrwersd&order_permission_request_token=AAAAAAAbDq-HJDXerDtj
    #
    # Body:
    #
    # { order_permission_verification_code: '123512321531145'
    # }
    #
    def create(community_id:, person_id: nil, order_permission_request_token:, body:)
      with_success_permissions(
        PaypalService::DataTypes::Permissions
        .create_get_access_token(
          {
            request_token: order_permission_request_token,
            verification_code: body[:order_permission_verification_code]
          })
      ) { |access_token|
        with_success_permissions(
          PaypalService::DataTypes::Permissions
          .create_get_basic_personal_data(
            {
              token: access_token[:token],
              token_secret: access_token[:token_secret]
            })
        ) { |personal_data|
          account = create_verified_account!(
            community_id: community_id,
            person_id: person_id,
            order_permission_request_token: order_permission_request_token,
            payer_id: personal_data[:payer_id],

            opts: {
              email: personal_data[:email],
              payer_id: personal_data[:payer_id],
              order_permission_request_token: order_permission_request_token,
              order_permission_verification_code: body[:order_permission_verification_code],
              order_permission_scope: access_token[:scope].join(','),
              active: true
            }
          )

          Result::Success.new(account)
        }
      }
    end

    ## POST /accounts/billing_agreement/request?community_id=1&person_id=asdfasdgasdfd
    #
    # Body:
    # { description: "Let marketplace take commission"
    # , success_url: "http://marketplace.com/success
    # , cancel_url: "http://marketplace.com/cancel
    # }
    #

    def billing_agreement_request(community_id:, person_id:, body:)
      # If a request for new billing agreement is made, delete old (not completely actived) billing agreement
      # Future note: This may not be sufficient solution when we implement the option to
      # switch PayPal account
      PaypalAccountStore.delete_billing_agreement(person_id: body[:person_id], community_id: body[:community_id])

      with_success_merchant(
        PaypalService::DataTypes::Merchant
        .create_setup_billing_agreement(
          {
            description: body[:description],
            success: body[:success_url],
            cancel: body[:cancel_url]
          })
      ) { |billing_agreement_request|
        account = PaypalAccountStore.update_active(
          community_id: community_id,
          person_id: person_id,
          opts:
            {
              community_id: community_id,
              person_id: person_id,
              billing_agreement_paypal_username_to: billing_agreement_request[:username_to],
              billing_agreement_request_token: billing_agreement_request[:token]
            })

        Result::Success.new(
          DataTypes.create_billing_agreement_request(
          {
            redirect_url: billing_agreement_request[:redirect_url]
          }))
      }
    end

    ## POST /accounts/billing_agreement/create?community_id=1&person_id=asdfgasdgasdfaasdf&billing_agreement_request_token=EC-123215122362
    #
    # Empty body
    #
    # Errors:
    #
    # - :billing_agreement_not_accepted
    # - :wrong_account

    def billing_agreement_create(community_id:, person_id:, billing_agreement_request_token:)
      paypal_account = PaypalAccountStore.get_active(person_id: person_id, community_id: community_id)

      with_success_merchant(
        PaypalService::DataTypes::Merchant
        .create_create_billing_agreement(
          {
            token: billing_agreement_request_token
          })
      ) { |billing_agreement|
        with_success_merchant(
          PaypalService::DataTypes::Merchant
          .create_get_express_checkout_details(
            {
              token: billing_agreement_request_token
            })
        ) { |express_checkout_details|
          if !express_checkout_details[:billing_agreement_accepted]
            Result::Error.new(:billing_agreement_not_accepted)
          elsif express_checkout_details[:payer_id] != paypal_account[:payer_id]
            Result::Error.new(:wrong_account)
          else
            account = PaypalAccountStore.update_active(
              community_id: community_id,
              person_id: person_id,
              opts:
                {
                  billing_agreement_billing_agreement_id: billing_agreement[:billing_agreement_id]
                })

            Result::Success.new(account)
          end
        }
      }
    end

    def delete_billing_agreement(community_id:, person_id:)
      PaypalAccountStore.delete_billing_agreement(
        person_id: person_id,
        community_id: community_id
      )

      Result::Success.new()
    end

    ## DELETE /accounts/?community_id=1&person_id=asdfgasdgasdfaasdf

    def delete(community_id:, person_id: nil)
      Result::Success.new(PaypalAccountStore.delete_all(person_id: person_id, community_id: community_id))
    end

    ## GET /accounts/?community_id=1&person_id=asdfgasdgasdfaasdf

    def get(community_id:, person_id: nil)
      Result::Success.new(PaypalAccountStore.get_active(person_id: person_id, community_id: community_id))
    end

    private

    def create_verified_account!(community_id:, person_id:nil, order_permission_request_token:, payer_id:, opts:)
      existing = PaypalAccountStore.get(
        community_id: community_id,
        person_id: person_id,
        payer_id: payer_id
      )

      if existing.nil?
        # Update the 'new' account
        PaypalAccountStore.update_pending(
          community_id: community_id,
          person_id: person_id,
          order_permission_request_token: order_permission_request_token,
          opts: opts
        )
      else
        # Delete the 'new' account
        PaypalAccountStore.delete_pending(
          community_id: community_id,
          person_id: person_id,
          order_permission_request_token: order_permission_request_token
        )

        # Update the 'existing' account
        PaypalAccountStore.update(
          community_id: community_id,
          person_id: person_id,
          payer_id: payer_id,
          opts: opts
        )
      end
    end

    # Calls Merchant API with given request
    # Logs and returns if error, calls block if success
    def with_success_merchant(req, &block)
      handle_response(req, @merchant.do_request(req), &block)
    end

    # Calls Permissions API with given request
    # Logs and returns if error, calls block if success
    def with_success_permissions(req, &block)
      handle_response(req, @permissions.do_request(req), &block)
    end

    def handle_response(req, res, &block)
      if res[:success]
        block.call(res)
      else
        res.tap { |err_response|
          @logger.warn("PayPal operation #{req[:method]} failed. Error code: #{err_response[:error_code]}, msg: #{err_response[:error_msg]}")
        }
      end
    end
  end
end
