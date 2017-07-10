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
      include Loggable

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
        data.screenshot = create_screenshot(data.source)
        data[AVAILABLE_ATTRIBUTE_NAME] = !data.screenshot.nil?
        yield(data)
      end

      private
      def create_screenshot(data)
        screenshot = nil

        view_context = WebKit2Gtk::WebContext.new(ephemeral: true)
        view = WebKit2Gtk::WebView.new(context: view_context)
        window = Gtk::OffscreenWindow.new
        window.set_default_size(800, 600)
        window.add(view)
        window.show_all

        finished = false
        view.signal_connect("load-changed") do |_, load_event|
          debug do
            "#{log_tag}[load][#{load_event.nick}] #{view.uri}"
          end

          case load_event
          when WebKit2Gtk::LoadEvent::FINISHED
            view.get_snapshot(:full_document, :none) do |_, result|
              finished = true
              snapshot_surface = view.get_snapshot_finish(result)
              unless snapshot_surface.width.zero?
                png = convert_snapshot_surface_to_png(data, snapshot_surface)
                screenshot = Screenshot.new("image/png",
                                            [png].pack("m*"),
                                            "base64")
              end
            end
          end
        end
        view.signal_connect("load-failed") do |_, _, failed_uri, error|
          finished = true
          error do
            message = "failed to load URI: #{failed_uri}: "
            message << "#{error.class}(#{error.code}): #{error.message}"
            "#{log_tag}[load][failed] #{message}"
          end
          true
        end
        debug do
          "#{log_tag}[load][html] #{data.uri}"
        end
        view.load_html(data.body, data.uri.to_s)

        main_context = GLib::MainContext.default
        until finished
          main_context.iteration(true)
        end

        screenshot
      end

      def convert_snapshot_surface_to_png(data, snapshot_surface)
        screenshot_width, screenshot_height = data.expected_screenshot_size

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

      def log_tag
        "[decomposer][webkit]"
      end
    end
  end
end
