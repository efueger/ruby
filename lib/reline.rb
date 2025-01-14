require 'io/console'
require 'reline/version'
require 'reline/config'
require 'reline/key_actor'
require 'reline/key_stroke'
require 'reline/line_editor'

module Reline
  extend self
  FILENAME_COMPLETION_PROC = nil
  USERNAME_COMPLETION_PROC = nil

  if RUBY_PLATFORM =~ /mswin|mingw/
    IS_WINDOWS = true
  else
    IS_WINDOWS = false
  end

  CursorPos = Struct.new(:x, :y)

  class << self
    attr_accessor :basic_quote_characters
    attr_accessor :completer_quote_characters
    attr_accessor :completer_word_break_characters
    attr_reader :completion_append_character
    attr_accessor :completion_case_fold
    attr_accessor :filename_quote_characters
    attr_accessor :special_prefixes
  end

  @@config = Reline::Config.new
  @@line_editor = Reline::LineEditor.new(@@config)
  @@ambiguous_width = nil

  HISTORY = Class.new(Array) {
    def to_s
      'HISTORY'
    end

    def delete_at(index)
      index = check_index(index)
      super(index)
    end

    def [](index)
      index = check_index(index)
      super(index)
    end

    def []=(index, val)
      index = check_index(index)
      super(index, String.new(val, encoding: Encoding::default_external))
    end

    def push(*val)
      super(*(val.map{ |v| String.new(v, encoding: Encoding::default_external) }))
    end

    def <<(val)
      super(String.new(val, encoding: Encoding::default_external))
    end

    private def check_index(index)
      index += size if index < 0
      raise RangeError.new("index=<#{index}>") if index < -@@config.history_size or @@config.history_size < index
      raise IndexError.new("index=<#{index}>") if index < 0 or size <= index
      index
    end
  }.new

  @basic_quote_characters = '"\''
  # TODO implement below
  #@completer_quote_characters
  #@completion_append_character
  #@completion_case_fold
  #@filename_quote_characters
  #@special_prefixes
  def self.completion_append_character=(val)
    if val.nil?
      @completion_append_character = nil
    elsif val.size == 1
      @completion_append_character = val
    elsif val.size > 1
      @completion_append_character = val[0]
    else
      @completion_append_character = nil
    end
  end

  @@basic_word_break_characters = " \t\n`><=;|&{("
  def self.basic_word_break_characters
    @@basic_word_break_characters
  end
  def self.basic_word_break_characters=(v)
    @@basic_word_break_characters = v
  end

  @@completer_word_break_characters = @@basic_word_break_characters.dup

  @@completion_proc = nil
  def self.completion_proc
    @@completion_proc
  end
  def self.completion_proc=(p)
    raise ArgumentError unless p.is_a?(Proc)
    @@completion_proc = p
  end

  @@pre_input_hook = nil
  def self.pre_input_hook
    @@pre_input_hook
  end
  def self.pre_input_hook=(p)
    @@pre_input_hook = p
  end

  @@dig_perfect_match_proc = nil
  def self.dig_perfect_match_proc
    @@dig_perfect_match_proc
  end
  def self.dig_perfect_match_proc=(p)
    @@dig_perfect_match_proc = p
  end

  def self.insert_text(text)
    @@line_editor&.insert_text(text)
    self
  end

  def self.redisplay
    @@line_editor&.rerender
  end

  def self.line_buffer
    @@line_editor&.line
  end

  def self.point
    @@line_editor ? @@line_editor.byte_pointer : 0
  end

  def self.point=(val)
    @@line_editor.byte_pointer = val
  end

  def self.delete_text(start = nil, length = nil)
    @@line_editor&.delete_text(start, length)
  end

  def self.input=(val)
    raise TypeError unless val.respond_to?(:getc) or val.nil?
    if val.respond_to?(:getc)
      Reline::GeneralIO.input = val
      remove_const('IO') if const_defined?('IO')
      const_set('IO', Reline::GeneralIO)
    end
  end

  @@output = STDOUT
  def self.output=(val)
    raise TypeError unless val.respond_to?(:write) or val.nil?
    @@output = val
  end

  def self.vi_editing_mode
    @@config.editing_mode = :vi_insert
    nil
  end

  def self.emacs_editing_mode
    @@config.editing_mode = :emacs
    nil
  end

  def self.vi_editing_mode?
    @@config.editing_mode_is?(:vi_insert, :vi_command)
  end

  def self.emacs_editing_mode?
    @@config.editing_mode_is?(:emacs)
  end

  def self.get_screen_size
    Reline::IO.get_screen_size
  end

  def retrieve_completion_block(line, byte_pointer)
    break_regexp = /[#{Regexp.escape(@@basic_word_break_characters)}]/
    before_pointer = line.byteslice(0, byte_pointer)
    break_point = before_pointer.rindex(break_regexp)
    if break_point
      preposing = before_pointer[0..(break_point)]
      block = before_pointer[(break_point + 1)..-1]
    else
      preposing = ''
      block = before_pointer
    end
    postposing = line.byteslice(byte_pointer, line.bytesize)
    [preposing, block, postposing]
  end

  def readmultiline(prompt = '', add_hist = false, &confirm_multiline_termination)
    if block_given?
      inner_readline(prompt, add_hist, true, &confirm_multiline_termination)
    else
      inner_readline(prompt, add_hist, true)
    end

    whole_buffer = @@line_editor.whole_buffer.dup
    whole_buffer.taint
    if add_hist and whole_buffer and whole_buffer.chomp.size > 0
      Reline::HISTORY << whole_buffer
    end

    @@line_editor.reset_line if @@line_editor.whole_buffer.nil?
    whole_buffer
  end

  def readline(prompt = '', add_hist = false)
    inner_readline(prompt, add_hist, false)

    line = @@line_editor.line.dup
    line.taint
    if add_hist and line and line.chomp.size > 0
      Reline::HISTORY << line.chomp
    end

    @@line_editor.reset_line if @@line_editor.line.nil?
    line
  end

  def inner_readline(prompt, add_hist, multiline, &confirm_multiline_termination)
    @@config.read
    otio = Reline::IO.prep

    may_req_ambiguous_char_width
    @@line_editor.reset(prompt)
    if multiline
      @@line_editor.multiline_on
      if block_given?
        @@line_editor.confirm_multiline_termination_proc = confirm_multiline_termination
      end
    else
      @@line_editor.multiline_off
    end
    @@line_editor.output = @@output
    @@line_editor.completion_proc = @@completion_proc
    @@line_editor.dig_perfect_match_proc = @@dig_perfect_match_proc
    @@line_editor.pre_input_hook = @@pre_input_hook
    @@line_editor.retrieve_completion_block = method(:retrieve_completion_block)
    @@line_editor.rerender

    if IS_WINDOWS
      config = {
        key_mapping: {
          [224, 72] => :ed_prev_history,    # ↑
          [224, 80] => :ed_next_history,    # ↓
          [224, 77] => :ed_next_char,       # →
          [224, 75] => :ed_prev_char        # ←
        }
      }
    else
      config = {
        key_mapping: {
          [27, 91, 65] => :ed_prev_history,    # ↑
          [27, 91, 66] => :ed_next_history,    # ↓
          [27, 91, 67] => :ed_next_char,       # →
          [27, 91, 68] => :ed_prev_char        # ←
        }
      }
    end

    key_stroke = Reline::KeyStroke.new(config)
    begin
      loop do
        c = Reline::IO.getc
        key_stroke.input_to!(c)&.then { |inputs|
          inputs.each { |c|
            @@line_editor.input_key(c)
            @@line_editor.rerender
          }
        }
        break if @@line_editor.finished?
      end
      Reline::IO.move_cursor_column(0)
    rescue StandardError => e
      Reline::IO.deprep(otio)
      raise e
    end

    Reline::IO.deprep(otio)
  end

  def may_req_ambiguous_char_width
    @@ambiguous_width = 2 if Reline::IO == Reline::GeneralIO or STDOUT.is_a?(File)
    return if @@ambiguous_width
    Reline::IO.move_cursor_column(0)
    print "\u{25bd}"
    @@ambiguous_width = Reline::IO.cursor_pos.x
    Reline::IO.move_cursor_column(0)
    Reline::IO.erase_after_cursor
  end

  def self.ambiguous_width
    @@ambiguous_width
  end
end

if Reline::IS_WINDOWS
  require 'reline/windows'
  Reline::IO = Reline::Windows
else
  require 'reline/ansi'
  Reline::IO = Reline::ANSI
end
require 'reline/general_io'
