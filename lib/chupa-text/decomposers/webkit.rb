# Copyright (C) 2017-2024  Sutou Kouhei <kou@clear-code.com>
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

require "English"
require "rbconfig"

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

      IN_PROCESS = ENV["CHUPA_TEXT_DECOMPOSER_WEBKIT_IN_PROCESS"] == "yes"
      if IN_PROCESS
        require "chupa-text-decomposer-webkit/screenshoter"
      end

      def decompose(data)
        body = data.source.body
        uri = data.source.uri.to_s
        output = Tempfile.new(["chupa-text-decomposer-webkit", ".png"])
        width, height = data.expected_screenshot_size
        if IN_PROCESS
          screenshoter = ChupaTextDecomposerWebKit::Screenshoter.new(logger)
          screenshoter.run(body, uri, output.path, width, height)
        else
          screenshoter = ExternalScreenshoter.new
          screenshoter.run(data.source.path, uri, output.path, width, height)
        end
        unless File.size(output.path).zero?
          png = output.read
          data.screenshot = Screenshot.new("image/png",
                                           [png].pack("m*"),
                                           "base64")
        end
        data[AVAILABLE_ATTRIBUTE_NAME] = !data.screenshot.nil?
        yield(data)
      end

      class ExternalScreenshoter
        include Loggable
        include LogTag

        def initialize
          @screenshoter = File.join(__dir__,
                                    "..",
                                    "..",
                                    "..",
                                    "bin",
                                    "chupa-text-decomposer-webkit-screenshoter")
          @command = ExternalCommand.new(RbConfig.ruby)
        end

        def run(html_path, uri, output_path, width, height)
          output_read, output_write = IO.pipe
          error_output = Tempfile.new("chupa-text-decomposer-webkit-error")
          output_reader = Thread.new do
            loop do
              IO.select([output_read])
              line = output_read.gets
              break if line.nil?

              case line.chomp
              when /\Adebug: /
                debug($POSTMATCH)
              when /\Aerror: /
                error($POSTMATCH)
              end
            end
          end
          successed = @command.run(@screenshoter,
                                   html_path.to_s,
                                   uri,
                                   output_path,
                                   width.to_s,
                                   height.to_s,
                                   {
                                     :spawn_options => {
                                       :out => output_write,
                                       :err => error_output.path,
                                     },
                                   })
          output_write.close
          output_reader.join

          unless successed
            error do
              message = "failed to external screenshoter: #{uri}: "
              message << "#{@command.path} #{@screenshoter}"
              "#{log_tag}[external-screenshoter][run][failed] #{message}"
            end
          end
          unless error_output.size.zero?
            error_output.each_line do |line|
              error(line)
            end
          end
        end
      end
    end
  end
end
