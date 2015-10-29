require 'nokogiri'
require 'open-uri'
require 'net/http'
require 'cgi'
require 'openssl'

class VersionTracker < ActiveRecord::Base
  MAC_UPDATE_SITE_URL = "https://www.macupdate.com"
  MAC_UPDATE_SEARCH_URL = "#{MAC_UPDATE_SITE_URL}/find/mac/"
  MAC_UPDATE_PACKAGE_URL = "#{MAC_UPDATE_SITE_URL}/app/mac/"

  has_many :download_links, :dependent => :destroy, :autosave => true

  belongs_to :package_branch
  belongs_to :icon, :dependent => :destroy, :autosave => true

  after_save :refresh_data
  after_create :background_fetch_data

  def self.update_all
    branches = PackageBranch.all
    branches.each do |branch|
      begin
        branch.version_tracker.fetch_data
        branch.save!
      rescue
        nil
      end
    end
  end

  def self.fetch_data(id)
    tracker = VersionTracker.where(:id => id).first
    if tracker.present?
      tracker.fetch_data
      tracker.save!
      tracker
    end
  end

  def refresh_data
    background_fetch_data if web_id_changed?
  end

  def background_fetch_data
    Backgrounder.call_rake("chore:fetch_version_tracker_data", :id => id)
  end

  def fetch_data
    self.web_id = retrieve_web_id if web_id.blank?
    page = NokogiriHelper.page(page_url)
    self.assign_data(scrape_data(page))
    self.icon = scrape_icon(page)
    self.download_links = scrape_download_links(page)
    self
  end

  def assign_data(data)
    self.version = data[:version].to_s
    self.description = data[:description].to_s
  end

  # Return true if macupdate is reachable
  def macupdate_is_up?
    begin
      uri = URI.parse(URI.escape(MAC_UPDATE_SITE_URL))
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      request = Net::HTTP::Get.new(uri.request_uri)
      response = http.request(request)
      response.instance_of?(Net::HTTPOK)
    rescue SocketError, Errno::ETIMEDOUT, Errno::ECONNREFUSED
      return false
    end
  end

  # URL to version tracker page
  def page_url
    MAC_UPDATE_PACKAGE_URL + "#{web_id}"
  end

  # Get all the download link and it's attributes
  def scrape_download_links(page)
    download_links = []
    page.css(".download_link").reject { |e| e[:href] == '#' }
                              .each do |link_element|
      download_url = MAC_UPDATE_SITE_URL + link_element[:href]
      text = link_element.text.lstrip.rstrip
      caption = link_element.parent().css('.download_link_app_version').text.lstrip.rstrip
      download_links << self.download_links.build({:text => text, :url => download_url, :caption => caption})
    end
    download_links
  end

  # Scrapes latest version from macupdate.com and return results
  def scrape_data(page, options = {})
    options = {:refresh_icon => false}.merge(options)
    {:version => NullObject.Maybe(page.at_css("#app_info_version_2")).text, :description => NullObject.Maybe(page.at_css("#short_descr_2")).text.lstrip.rstrip }
  end

  # Get the package icon download url and download the icon
  def scrape_icon(page)
    if image_element = page.at_css("#app_info_logo")
      url_string = image_element[:src]
      image_file = open(MAC_UPDATE_SITE_URL + url_string)
      icon = Icon.new({:photo => image_file})
      icon if icon.save
    end
  end

  def url_to_file(url_string)
    uri = URI.parse(URI.escape(url_string))
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    request = Net::HTTP::Get.new(uri.request_uri)
    response_body = http.request(request).body
  end

  # Retrieves and returns web ID of first search result
  def retrieve_web_id
    if macupdate_is_up?
      page = NokogiriHelper.page(MAC_UPDATE_SEARCH_URL + package_branch.display_name)
      link = page.css(".nfmlulrapt-link").first
      if link.present?
        url = link[:href]
        url.match(/([0-9]{4,})/)[1].to_i
      end
    end
  end
end
