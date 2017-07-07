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
      registry.register("webkit", self)

      TARGET_EXTENSIONS = ["htm", "html", "xhtml"]
      TARGET_MIME_TYPES = [
        "text/html",
        "application/xhtml+xml",
      ]
      def target?(data)
        return false unless data.need_screenshot?
        return false if data.screenshot

        source = data.source
        return false if source.nil?

        return true if TARGET_EXTENSIONS.include?(source.extension)
        return true if TARGET_MIME_TYPES.include?(source.mime_type)

        false
      end

      def decompose(data)
        data.screenshot = create_screenshot(data.source)
        yield(data)
      end

      private
      def create_screenshot(data)
        screenshot = nil

        screenshot_width, screenshot_height = data.expected_screenshot_size

        main_context = GLib::MainContext.default
        view = WebKit2Gtk::WebView.new
        view.load_uri(data.uri.to_s)
        finished = false
        view.signal_connect("load-changed") do |_, load_event|
          case load_event
          when WebKit2Gtk::LoadEvent::FINISHED
            view.get_snapshot(:full_document, :none) do |_, result|
              finished = true
              snapshot_surface = view.get_snapshot_finish(result)
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
              screenshot = Screenshot.new("image/png",
                                          [png.string].pack("m*"),
                                          "base64")
            end
          end
        end
        view.signal_connect("load-failed") do |_, _, failed_uri, error|
          finished = true
          message = "failed to load URI: #{failed_uri}: "
          message << "#{error.class}(#{error.code}): #{error.message}"
          puts(message)
          true
        end
        until finished
          main_context.iteration(true)
        end

        screenshot
      end
    end
  end
end
