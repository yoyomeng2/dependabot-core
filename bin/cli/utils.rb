# frozen_string_literal: true

module CLI
  class Utils
    def self.wildcard_match?(wildcard_string, candidate_string)
      return false unless wildcard_string && candidate_string

      regex_string = "a#{wildcard_string.downcase}a".split("*").
                    map { |p| Regexp.quote(p) }.
                    join(".*").gsub(/^a|a$/, "")
      regex = /^#{regex_string}$/
      regex.match?(candidate_string.downcase)
    end

    def self.show_diff(original_file, updated_file)
      return unless original_file

      if original_file.content == updated_file.content
        puts "    no change to #{original_file.name}"
        return
      end

      original_tmp_file = Tempfile.new("original")
      original_tmp_file.write(original_file.content)
      original_tmp_file.close

      updated_tmp_file = Tempfile.new("updated")
      updated_tmp_file.write(updated_file.content)
      updated_tmp_file.close

      diff = `diff #{original_tmp_file.path} #{updated_tmp_file.path}`
      puts
      puts "    ± #{original_file.name}"
      puts "    ~~~"
      puts diff.lines.map { |line| "    " + line }.join("")
      puts "    ~~~"
    end
  end
end
