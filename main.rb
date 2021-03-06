require 'capybara'
require 'capybara/user_agent'
require 'capybara/poltergeist'
require 'capybara/dsl'
require 'pp'
require 'mongo'
require 'twitter'
require 'open-uri'
load File.expand_path('../../conf/conf.rb', __FILE__)

OpenURI::Buffer.send :remove_const, 'StringMax' if OpenURI::Buffer.const_defined?('StringMax')
OpenURI::Buffer.const_set 'StringMax', 0

class SuperNukotan
	include Capybara::DSL
	def initialize ()
		# configure parameters in capybara
		Capybara::UserAgent.add_user_agents(your_browser: 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/52.0.2743.116 Safari/537.36')
		Capybara.register_driver :poltergeist do |app|
			Capybara::Poltergeist::Driver.new(app, {:js_errors => false, :timeout => 1000})
		end

		# establish database connection
		db = Mongo::Client.new(['127.0.0.1:27017'], :database => 'nukotan')
		@coll = db[:articles]

		# configure parameters in twitter oauth
		conf = nukotan_context()

		@client = Twitter::REST::Client.new do |config|
			config.consumer_key = conf[:tweet][:consumer_key]
			config.consumer_secret = conf[:tweet][:consumer_secret]
			config.access_token = conf[:tweet][:access_token]
			config.access_token_secret = conf[:tweet][:access_token_secret]
		end
	end

	def insert_record (record)
		@coll.insert_one(record)
		pp record
	end
end

class Instagram < SuperNukotan
	def initialize ()
		@base_fqdn = 'https://www.instagram.com'
		@base_path = '/kuroneko_omz/'
		super()
		@session = Capybara::Session.new(:poltergeist)
		@session.visit @base_fqdn + @base_path
	end

	def get_newest_url
		instagram_doc = Nokogiri::HTML.parse(@session.html)
		instagram_json = instagram_doc.xpath('//script[contains(text(),"window._sharedData")]').text[/^[^{]+({.+})/, 1]
		contents = JSON.parse(instagram_json)
		code = contents['entry_data']['ProfilePage'][0]['user']['media']['nodes'][0]['code']
	
		return @base_fqdn + '/p/' + code + '/?taken-by=kuroneko_omz'
	end

	def get_newest_detail(newest_url)
		session = Capybara::Session.new(:poltergeist)
		session.visit newest_url
		instagram_doc = Nokogiri::HTML.parse(session.html)
		instagram_json = instagram_doc.xpath('//script[contains(text(),"window._sharedData")]').text[/^[^{]+({.+})/, 1]
		contents = JSON.parse(instagram_json)

		node = contents['entry_data']['PostPage'][0]['graphql']['shortcode_media']

		newest = {}
		newest[:path] = newest_url
		newest[:body] = node['edge_media_to_caption']['edges'][0]['node']['text']
		newest[:date] = Time.now.strftime('%Y-%m-%d %H:%M:%S')

		if node['edge_sidecar_to_children'] then
			newest[:images] = []
			node['edge_sidecar_to_children']['edges'].each do |edge|
				newest[:images].push(edge['node']['display_url'])
			end
		else
			newest[:images] = [node['display_url']]
		end

		return newest
	end

	def check_newest_info (isprod)
		newest_url = get_newest_url
	
		if @coll.find({'path' => newest_url}).count == 0 then
			p 'Update Instagram: '
			newest = get_newest_detail(newest_url)
			pp newest
			tweet = Tweet.new()
			tweet.send_newest_tweet(isprod, 'instagram', newest)
			insert_record(newest)
		end
	end
end

class Nekomamma < SuperNukotan
	def initialize ()
		@base_fqdn = 'http://nekomamma.jugem.jp'
		@base_path = ''
		super()
		@session = Capybara::Session.new(:poltergeist)
		@session.visit @base_fqdn + @base_path
	end

	def get_newest_info
		doc = Nokogiri::HTML.parse(@session.html)
		elem = doc.css('table.entry').first
		newest = {}
		newests = []
		newest[:title] = elem.css('div.entry_title').text
		newest[:body] = elem.css('div.jgm_entry_desc_mark').text
		images = []
		elem.css('img.pict').each do |image|
			images << image.attribute('src').value
		end
		newest[:images] = images
		
		newest[:path] = @base_fqdn + elem.css('div.entry_state > a').first[:href].gsub(/\./, '')
		newest[:date] = elem.css('div.entry_date').text.split(' ')[0].gsub(/\./, "-") + ' ' + elem.css('div.entry_state > a').text
		
		splited = split_article_body(newest[:body])
		splited.each do |p|
			newests << {
				:title => newest[:title],
				:path => newest[:path],
				:date => newest[:date],
				:images => newest[:images],
				:body => p,
			}
		end
		pp newests
		return newests
	end

	def check_newest_info (isprod)
		newests = get_newest_info
		if @coll.find({'path' => newests.first[:path]}).count == 0 then
			tweet = Tweet.new()
			tweet.send_newest_tweet(isprod, 'nekomamma', newests.first)
			newests.each do |newest|
				insert_record(newest)
			end
		end
	end

	def get_archive_info (isinsert)
		doc = Nokogiri::HTML.parse(@session.html)
		i = 0
		doc.css('div.menu_box').each do |list|
			if i == 3 then
				list.css('a').each do |archive_date|
					@session.click_link(archive_date.text)
					doc = Nokogiri::HTML.parse(@session.html)
					doc.css('td.cell > a').each do |article_date|
						@session.click_link(article_date.text)
						newests = get_newest_info
						newests.each do |newest|	
							insert_record(newest) if isinsert
						end
					end
				end
			end	
			i += 1
		end
	end

	def split_article_body (article_body)
		splited1 = article_body.gsub(/(\R|[[:space:]])/, '').split("")
		splited2 = []
		tmp = before_p = ""
		isfirst = true
		block_detected = false
		splited1.each do |p|
			if p =~ /（|「/ then
				block_detected = true
				tmp << p
				before_p = p
				next
			end
			if p =~ /）|」/ then
				block_detected = false
				tmp << p
				before_p = p
				next
			end
			if !block_detected then
				if !isfirst && before_p == "！" && p !~ /！|）|」/ then
					splited2 << tmp
					tmp = p
				elsif p =~ /。|？|♪/ then
					splited2 << tmp + p
					tmp = ""
				else
					tmp << p
				end
			else
				tmp << p
			end
			if !isfirst then
				before_p = p
                        end
			isfirst = false
		end
		pp splited2
	end
end

class Tweet < SuperNukotan
	def initialize
		super()
	end

	def select_tweet
		prng = Random.new()
		@coll.find().skip((prng.rand * @coll.count()).round).limit(1).each do |record|
			pp record
			return record
		end
	end

	def send_stored_tweet(isprod)
		record = select_tweet
		if isprod then
			if record['body'].length >= 90 then
				message = (record['body'])[0, 87] + "...\n" + record['path']
			else 
				message = record['body'] + "\n" + record['path']
			end
			if record['images'].length == 0 then
				@client.update(message)
			else
				media_ids = select_medias(record[:images])
				@client.update message, {media_ids: media_ids.join(',')} if isprod
			end
		end
	end

	def send_newest_tweet(isprod, type, newest)
		case
		when type == 'instagram'
			message = "ぬこたんInstagramが更新されました(*´Д`)ﾊｧﾊｧ\n\n"
			if newest[:body].length >= 50 then
				message += (newest[:body])[0, 47] + "...\n"
			else
				message += newest[:body] + "\n"
			end
			message += newest[:path]

			media_ids = []
			if isprod then
				media_ids = select_medias(newest[:images])
				@client.update message, {media_ids: media_ids.join(',')} if isprod
			end
		when type == 'nekomamma'
			message = ("黒猫のねこまんま通信が更新されました(*´Д`)ﾊｧﾊｧ\n\n" + newest[:title])[0, 110] + "\n" + newest[:path]
			if newest[:images].length == 0 then
				@client.update(message) if isprod
			else
				media_ids = []
				if isprod then
					media_ids = select_medias(newest[:images])
					@client.update message, {media_ids: media_ids.join(',')} if isprod
				end
			end
		else
			0
		end
	end

	def select_medias(images)
		media_ids = []
		images.shuffle.each do |image_path|
			media = open(image_path)
			media_ids << @client.upload(media)
			if media_ids.length == 4 then
				break
			end
		end
		return media_ids
	end
		
end

