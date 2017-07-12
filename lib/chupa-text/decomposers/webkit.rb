# Copyright (C) 2017  Kouhei Sutou <kou@clear-code.com>
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

require "webkit2-gtk"

module ChupaText
  module Decomposers
    class WebKit < Decomposer
      module LogTag
        private
        def log_tag
          "[decomposer][webkit]"
        end
      end

      include Loggable
      include LogTag

      registry.register("webkit", self)

      TARGET_EXTENSIONS = ["htm", "html", "xhtml"]
      TARGET_MIME_TYPES = [
        "text/html",
        "application/xhtml+xml",
      ]
      AVAILABLE_ATTRIBUTE_NAME = "decomposer-webkit-screenshot-available"
      def target?(data)
        return false unless data.need_screenshot?
        return false if data.screenshot
        return false unless data[AVAILABLE_ATTRIBUTE_NAME].nil?

        source = data.source
        return false if source.nil?

        return true if TARGET_EXTENSIONS.include?(source.extension)
        return true if TARGET_MIME_TYPES.include?(source.mime_type)

        source_body = source.body
        return false if source_body.nil?

        return true if source_body.start_with?("<!DOCTYPE html ")
        return true if source_body.start_with?("<html")

        false
      end

      def decompose(data)
        screenshoter = Screenshoter.new(data)
        screenshoter.run
        data[AVAILABLE_ATTRIBUTE_NAME] = !data.screenshot.nil?
        yield(data)
      end

      class Screenshoter
        include Loggable
        include LogTag

        def initialize(data)
          @data = data
          @@view_context ||= create_view_context
          @main_loop = GLib::MainLoop.new(nil, false)
          @timeout_second = compute_timeout_second
        end

        def run
          view = WebKit2Gtk::WebView.new(context: @@view_context)
          window = Gtk::OffscreenWindow.new
          window.set_default_size(800, 600)
          window.add(view)
          window.show_all

          setup_callbacks(view)

          timeout(view) do
            debug do
              "#{log_tag}[load][HTML] #{@data.uri}"
            end
            view.load_html(@data.source.body, @data.source.uri.to_s)
            @main_loop.run
          end

          window.destroy
        end

        private
        def create_view_context
          context = WebKit2Gtk::WebContext.new(ephemeral: true)
          http_proxy = ENV["http_proxy"]
          https_proxy = ENV["https_proxy"]
          ftp_proxy = ENV["ftp_proxy"]
          if http_proxy or https_proxy or ftp_proxy
            proxy_settings = WebKit2Gtk::NetworkProxySettings.new
            if http_proxy
              proxy_settings.add_proxy_for_scheme("http", http_proxy)
            end
            if https_proxy
              proxy_settings.add_proxy_for_scheme("https", https_proxy)
            end
            if ftp_proxy
              proxy_settings.add_proxy_for_scheme("ftp", ftp_proxy)
            end
            context.set_network_proxy_settings(:custom, proxy_settings)
          end
          context
        end

        def setup_callbacks(view)
          view.signal_connect("load-changed") do |_, load_event|
            debug do
              "#{log_tag}[load][#{load_event.nick}] #{view.uri}"
            end

            case load_event
            when WebKit2Gtk::LoadEvent::FINISHED
              debug do
                "#{log_tag}[screenshot][start] #{view.uri}"
              end
              view.get_snapshot(:full_document, :none) do |_, result|
                @main_loop.quit
                snapshot_surface = view.get_snapshot_finish(result)
                debug do
                  size = "#{snapshot_surface.width}x#{snapshot_surface.height}"
                  "#{log_tag}[screenshot][finish] #{view.uri}: #{size}"
                end
                unless snapshot_surface.width.zero?
                  png = convert_snapshot_surface_to_png(snapshot_surface)
                  @data.screenshot = Screenshot.new("image/png",
                                                    [png].pack("m*"),
                                                    "base64")
                end
              end
            end
          end
          view.signal_connect("load-failed") do |_, _, failed_uri, error|
            @main_loop.quit
            error do
              message = "failed to load URI: #{failed_uri}: "
              message << "#{error.class}(#{error.code}): #{error.message}"
              "#{log_tag}[load][failed] #{message}"
            end
            true
          end
        end

        def convert_snapshot_surface_to_png(snapshot_surface)
          screenshot_width, screenshot_height = @data.expected_screenshot_size

          screenshot_surface = Cairo::ImageSurface.new(:argb32,
                                                       screenshot_width,
                                                       screenshot_height)
          context = Cairo::Context.new(screenshot_surface)
          context.set_source_color(:white)
          context.paint

          ratio = screenshot_width.to_f / snapshot_surface.width
          context.scale(ratio, ratio)
          context.set_source(snapshot_surface)
          context.paint

          png = StringIO.new
          screenshot_surface.write_to_png(png)
          png.string
        end

        def timeout(view)
          timeout_id = GLib::Timeout.add_seconds(@timeout_second) do
            timeout_id = nil
            error do
              message = "timeout to load URI: #{@timeout_second}s: #{view.uri}"
              message << ": loading" if view.loading?
              "#{log_tag}[load][timeout] #{message}"
            end
            if view.loading?
              view.signal_connect("close") do
                @main_loop.quit
                error do
                  "#{log_tag}[load][closed] #{view.uri}"
                end
              end
              view.try_close
            else
              @main_loop.quit
            end
            GLib::Source::REMOVE
          end

          begin
            yield
          ensure
            GLib::Source.remove(timeout_id) if timeout_id
          end
        end

        def compute_timeout_second
          default_timeout = 5
          timeout_string =
            ENV["CHUPA_TEXT_DECOMPOSER_WEBKIT_TIMEOUT"] || default_timeout.to_s
          begin
            Integer(timeout_string)
          rescue ArgumentError
            default_timeout
          end
        end
      end
    end
  end
end
