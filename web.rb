require 'sinatra'
require 'stripe'
require 'dotenv'
require 'json'
require 'encrypted_cookie'

Dotenv.load
Stripe.api_key = ENV['STRIPE_TEST_SECRET_KEY']

use Rack::Session::EncryptedCookie,
  :secret => 'replace_me_with_a_real_secret_key' # ¡En realidad usa algo secreto aquí!

def log_info(message)
  puts "\n" + message + "\n\n"
  return message
end

get '/' do
  status 200
  return log_info("Great, your backend is set up. Now you can configure the Stripe example apps to point here.")
end

post '/ephemeral_keys' do
  authenticate(params[:customer_id])
  begin
    key = Stripe::EphemeralKey.create(
      {customer: @customer.id},
      {stripe_version: params["api_version"]}
    )
  rescue Stripe::StripeError => e
    status 402
    return log_info("Error creating ephemeral key: #{e.message}")
  end

  content_type :json
  status 200
  key.to_json
end

post '/refund_payment' do
  payload = params
  # Obtenga los detalles de la tarjeta de crédito enviados
  if request.content_type.include? 'application/json' and params.empty?
    payload = Sinatra::IndifferentHash[JSON.parse(request.body.read)]
  end

  # Crear y capturar el PaymentIntent a través de la API de Stripe: esto cargará la tarjeta del usuario
  begin
    refund = Stripe::Refund.create({
      amount: payload[:amount],
      payment_intent: payload[:payment_intent]
    })
  rescue Stripe::StripeError => e
    status 402
    return log_info("Error: #{e.message}")
  end

  status 200
  return {
      :refund => refund
  }.to_json
end

post '/capture_payment' do
  payload = params
  # Obtenga los detalles de la tarjeta de crédito enviados
  if request.content_type.include? 'application/json' and params.empty?
    payload = Sinatra::IndifferentHash[JSON.parse(request.body.read)]
  end

  # Crear y capturar el PaymentIntent a través de la API de Stripe: esto cargará la tarjeta del usuario
  begin
    payment_intent = create_and_capture_payment_intent(
      payload[:amount],
      payload[:source],
      payload[:payment_method],
      payload[:customer_id],
      payload[:metadata],
      'mxn',
      payload[:shipping],
      payload[:return_url],
      payload[:description]
    )
  rescue Stripe::StripeError => e
    status 402
    return log_info("Error: #{e.message}")
  end

  status 200
  return {
      :secret => payment_intent.client_secret
  }.to_json
end

post '/confirm_payment' do
  payload = params
  if request.content_type.include? 'application/json' and params.empty?
      payload = Sinatra::IndifferentHash[JSON.parse(request.body.read)]
  end
  begin
      payment_intent = Stripe::PaymentIntent.confirm(payload[:payment_intent_id], {:use_stripe_sdk => true})
      rescue Stripe::StripeError => e
      status 402
      return log_info("Error: #{e.message}")
  end

  status 200
  return {
      :secret => payment_intent.client_secret
  }.to_json
end

def authenticate(customerId)
  # Este código simula "cargar el cliente Stripe para su sesión actual".
  # Su propia lógica probablemente se verá muy diferente.
  if customerId.nil?
    @customer = Stripe::Customer.create(
      :description => 'mobile SDK example customer',
      :metadata => {
        # Agregue el ID de cliente de nuestra aplicación para este Cliente, para que sea más fácil buscar
        :my_customer_id => '72F8C533-FCD5-47A6-A45B-3956CA8C792D',
      },
    )
  else
    @customer = Stripe::Customer.retrieve(customerId)
  end
  @customer
end

# Las aplicaciones de ejemplo móviles utilizan este punto final para crear un SetupIntent.
# https://stripe.com/docs/api/setup_intents/create
# Al igual que el punto final `/ capture_payment`, una implementación real incluiría controles
# para evitar el mal uso
post '/create_setup_intent' do
  payload = params
  if request.content_type != nil and request.content_type.include? 'application/json' and params.empty?
      payload = Sinatra::IndifferentHash[JSON.parse(request.body.read)]
  end
  begin
    setup_intent = Stripe::SetupIntent.create({
      payment_method_types: ['card'],
      payment_method: payload[:payment_method],
      return_url: payload[:return_url],
      confirm: payload[:payment_method] != nil,
      use_stripe_sdk: payload[:payment_method] != nil ? true : nil,
    })
  rescue Stripe::StripeError => e
    status 402
    return log_info("Error creating SetupIntent: #{e.message}")
  end

  log_info("SetupIntent successfully created: #{setup_intent.id}")
  status 200
  return {
    :intent => setup_intent.id,
    :secret => setup_intent.client_secret,
    :status => setup_intent.status
  }.to_json
end

# Este punto final lo utilizan las aplicaciones de ejemplo móviles para crear un PaymentIntent.
# https://stripe.com/docs/api/payment_intents/create
# Al igual que el punto final `/ capture_payment`, una implementación real incluiría controles
# para evitar el mal uso
post '/create_intent' do
  begin
    payment_intent = create_payment_intent(
      params[:amount],
      nil,
      nil,
      nil,
      params[:metadata],
      'mxn',
      nil,
      nil
    )
  rescue Stripe::StripeError => e
    status 402
    return log_info("Error creating PaymentIntent: #{e.message}")
  end

  log_info("PaymentIntent successfully created: #{payment_intent.id}")
  status 200
  return {
    :intent => payment_intent.id,
    :secret => payment_intent.client_secret,
    :status => payment_intent.status
  }.to_json
end

# This endpoint responds to webhooks sent by Stripe. To use it, you'll need
# to add its URL (https://{your-app-name}.herokuapp.com/stripe-webhook)
# in the webhook settings section of the Dashboard.
# https://dashboard.stripe.com/account/webhooks
post '/stripe-webhook' do
  json = JSON.parse(request.body.read)

  # Retrieving the event from Stripe guarantees its authenticity
  event = Stripe::Event.retrieve(json["id"])
  source = event.data.object

  # For sources that require additional user action from your customer
  # (e.g. authorizing the payment with their bank), you should use webhooks
  # to capture a PaymentIntent after the source becomes chargeable.
  # For more information, see https://stripe.com/docs/sources#best-practices
  WEBHOOK_CHARGE_CREATION_TYPES = ['bancontact', 'giropay', 'ideal', 'sofort', 'three_d_secure']
  if event.type == 'source.chargeable' && WEBHOOK_CHARGE_CREATION_TYPES.include?(source.type)
    begin
      create_and_capture_payment_intent(
        source.amount,
        source.id,
        nil,
        source.metadata["customer"],
        source.metadata,
        source.currency,
        nil,
        nil
      )
    rescue Stripe::StripeError => e
      return log_info("Error creating PaymentIntent: #{e.message}")
    end
    # After successfully capturing a PaymentIntent, you should complete your customer's
    # order and notify them that their order has been fulfilled (e.g. by sending
    # an email). When creating the source in your app, consider storing any order
    # information (e.g. order number) as metadata so that you can retrieve it
    # here and use it to complete your customer's purchase.
  end
  status 200
end

def create_payment_intent(amount, source_id, payment_method_id, customer_id = nil,
                          metadata = {}, currency = 'mxn', shipping = nil, return_url = nil, confirm = false, description)
  return Stripe::PaymentIntent.create(
    :amount => amount,
    :currency => currency || 'mxn',
    :customer => customer_id,
    :source => source_id,
    :payment_method => payment_method_id,
    :payment_method_types => ['card'],
    :description => description,
    :shipping => shipping,
    :return_url => return_url,
    :confirm => confirm,
    :confirmation_method => confirm ? "manual" : "automatic",
    :use_stripe_sdk => confirm ? true : nil,
    :capture_method => ENV['CAPTURE_METHOD'] == "manual" ? "manual" : "automatic",
    :metadata => {
      :order_id => '5278735C-1F40-407D-933A-286E463E72D8',
    }.merge(metadata || {}),
  )
end

def create_and_capture_payment_intent(amount, source_id, payment_method_id, customer_id = nil,
                                      metadata = {}, currency = 'usd', shipping = nil, return_url = nil, description)
  payment_intent = create_payment_intent(amount, source_id, payment_method_id, customer_id,
                                          metadata, currency, shipping, return_url, true, description)
  return payment_intent
end
