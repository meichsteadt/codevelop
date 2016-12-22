require 'bundler/setup'
require 'dotenv'
require 'sinatra'
require 'rest-client'
require 'json'
require 'bcrypt'
Dotenv.load
Bundler.require(:default)
Dir[File.dirname(__FILE__) + '/lib/*.rb'].each { |file| require file }
enable :sessions

if ENV['GH_BASIC_CLIENT_ID'] && ENV['GH_BASIC_SECRET_ID']
 CLIENT_ID        = ENV['GH_BASIC_CLIENT_ID']
 CLIENT_SECRET    = ENV['GH_BASIC_SECRET_ID']
end
use Rack::Session::Pool, :cookie_only => false

def logged_in?
  session[:id]
end

def authenticated?
  session[:access_token]
end

def authenticate!
  erb :sign_up, :locals => {:client_id => CLIENT_ID}
end

def login
  @user = User.find_by(email: params[:username])
  @user.nil? ? @user = User.find_by(user_name: params[:username]) : false
  if @user.nil?
    session[:error] = "Looks like no one exists with that username/password"
    redirect to '/sign_in'
  elsif @user.password == params[:password]
    session[:id] = @user.id
  else
    session[:error] = "Incorrect password. Try again my friend"
    redirect to '/sign_in'
  end
end

get '/' do
  erb :index
end

get '/sign_up' do
  erb :sign_up
end

post '/sign_up' do
  user = params[:user_name]
  email = params[:email]
  profile_picture = params[:profile_picture]
  if User.exists?(user_name: user)
    session[:error] = "That username is already taken"
    redirect '/sign_up'
  elsif User.exists?(email: email)
    session[:error] = "That email is already taken"
    redirect '/sign_up'
  else
    @user = User.new({user_name: user, email: email, profile_picture: profile_picture, online: true})
    @user.password = params[:password1]
    if @user.save!
    session[:id] = @user.id
    redirect '/home'
    else
      session[:error] = "There was a problem saving your profile"
      redirect '/sign_up'
    end
  end
end

get '/home' do
  @user = User.find(session[:id])
    @users = User.all
  @posts = []
  @user.followings.each do |following|
    follow = User.find(following.user_id.to_i)
    follow.posts.each do |post|
      @posts.push(post)
    end
  end
  @online_users = []
  User.all.each do |user|
    user.online and user.id != @user.id ? @online_users.push(user) : false
  end
  erb :home
end

get '/sign_in' do
  erb :sign_in, :locals => {:errors => session[:error]}
end

patch '/sign_in' do
  login
  user = User.find(session[:id])
  user.update({online: true})
  redirect '/home'
end

get '/logout' do
  User.update(session[:id], {online: false})
  session.clear
  redirect '/sign_in'
end

get '/github' do
  if !authenticated?
    authenticate!
  else
    access_token = session[:access_token]
    scopes = []

    begin
      auth_result = RestClient.get('https://api.github.com/user',
                                   {:params => {:access_token => access_token},
                                    :accept => :json})
    rescue => e
      # request didn't succeed because the token was revoked so we
      # invalidate the token stored in the session and render the
      # index page so that the user can start the OAuth flow again

      session[:access_token] = nil
      binding.pry
      return authenticate!
    end

    @auth_result = JSON.parse(auth_result)
    @auth_result['private_emails'] =
        JSON.parse(RestClient.get('https://api.github.com/user/emails',
                       {:params => {:access_token => access_token},
                        :accept => :json}))


    session[:user] = @auth_result['login']
    @user_name = @auth_result['login']
    @email = @auth_result['private_emails'][0]['email']
    @profile_picture = @auth_result['avatar_url']
    erb :sign_up
  end
end

get '/callback' do
  session_code = request.env['rack.request.query_hash']['code']

  result = RestClient.post('https://github.com/login/oauth/access_token',
                          {:client_id => CLIENT_ID,
                           :client_secret => CLIENT_SECRET,
                           :code => session_code},
                           :accept => :json)

  session[:access_token] = JSON.parse(result)['access_token']
  redirect '/github'
end

get '/conversation/:id' do
  @user = User.find(params[:id])
  erb :conversation, :layout => (request.xhr? ? false : :layout)
end

get '/messages' do
  user = User.find(session[:id])
  @users = []
  user.messages.each do |message|
    if message.sender_id != user.id && !@users.include?(User.find(message.sender_id.to_i))
      @users.push(User.find(message.sender_id.to_i))
    elsif message.receiver_id != user.id && !@users.include?(User.find(message.receiver_id.to_i))
        @users.push(User.find(message.receiver_id.to_i))
    end
  end
  # binding.pry
  erb :messages
end

get '/message/new' do
  @users = User.all
  erb :message_form
end

post '/message' do
  @user = User.find(session[:id])
  receiver = User.find_by(email: params[:receiver_id])
  new_message = Message.create(content: params[:content], receiver_id: receiver.id.to_i, sender_id: @user.id.to_i)
  if @user.messages.push(new_message) && receiver.messages.push(new_message)
    session[:recent] = User.find_by(email: params[:receiver_id]).id.to_i
    redirect '/messages'
  else
  erb :message_form
  end
end

get '/recent_message' do
  @user = User.find(session[:recent])
  erb :recent_conversation, :layout => (request.xhr? ? false : :layout)
end

get '/method' do
  User.all.each(&:destroy)
  redirect '/messages'
end

get '/teams/new' do
  erb :team_create
end

post '/teams/:id' do
  name = params[:team_name]
  logo = params[:logo_url]
  bio = params[:team_bio]
  Team.create({name: name, team_info: bio, logo: logo})
  redirect '/team/:id'
end

get '/search' do
  if params[:query]
    search = params[:query] + "%"
    @users = User.where('user_name LIKE ?', search)
    @teams = Team.where('name LIKE ?', search)
    @language = Language.where('name LIKE ?', search)
    erb :results
  end
end

get '/teams' do
  @teams = Team.all()
  @user = User.find(session[:id])
  erb :teams
end

post '/post_content' do
  @user = User.find(session[:id])
  content = params[:content]
  new_post = Post.create(content: content)
  @user.posts.push(new_post)
  redirect '/home'
end

get '/user/:id' do
  @user = User.find(session[:id].to_i)
  @following = User.find(params[:id].to_i)
  @user.followings.create({following_id: @following.id.to_i})
  redirect '/home'
end
# get '/teams/:id' do
#
# end
#
# patch 'teams/:id' do
#
# end
#
# delete 'teams/:id' do
#
# end
