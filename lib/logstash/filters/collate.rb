# encoding: utf-8
require "logstash/filters/base"
require "logstash/namespace"


# Collate events by time or count.
#
# The original goal of this filter was to merge the logs from different sources
# by the time of log, for example, in real-time log collection, logs can be
# collated by amount of 3000 logs or can be collated in 30 seconds.
#
# The config looks like this:
# [source,ruby]
#     filter {
#       collate {
#         count => 3000
#         interval => "30s"
#         order => "ascending"
#       }
#     }
class LogStash::Filters::Collate < LogStash::Filters::Base

  config_name "collate"

  # How many logs should be collated.
  config :count, :validate => :number, :default => 1000

  # The `interval` is the time window which how long the logs should be collated. (default `1m`)
  config :interval, :validate => :string, :default => "1m"

  # The `order` collated events should appear in.
  config :order, :validate => ["ascending", "descending"], :default => "ascending"

  public
  def register
    require "thread"
    require "rufus/scheduler"

    @mutex = Mutex.new
    @collatingDone = false
    @collatingArray = Array.new
    @scheduler = Rufus::Scheduler.new
    @job = @scheduler.every @interval do
      @logger.info("Scheduler Activated")
      @mutex.synchronize{
        collate
      }
    end
  end # def register

  public
  def filter(event)
    @logger.info("do collate filter")
    if event == LogStash::SHUTDOWN
      @job.trigger()
      @job.unschedule()
      @logger.info("collate filter thread shutdown.")
      return
    end

    # if the event is collated, a "collated" tag will be marked, so for those uncollated event, cancel them first.
    if event["tags"].nil? || !event["tags"].include?("collated")
      event.cancel
    else
      return
    end

    @mutex.synchronize{
      @collatingArray.push(event.clone)

      if (@collatingArray.length == @count)
        collate
      end

      if (@collatingDone)
        while collatedEvent = @collatingArray.pop
          collatedEvent["tags"] = Array.new if collatedEvent["tags"].nil?
          collatedEvent["tags"] << "collated"
          filter_matched(collatedEvent)
          yield collatedEvent
        end # while @collatingArray.pop
        # reset collatingDone flag
        @collatingDone = false
      end
    }
  end # def filter

  private
  def collate
    if (@order == "ascending")
      # call .to_i for now until https://github.com/elasticsearch/logstash/issues/2052 is fixed
      @collatingArray.sort! { |eventA, eventB| eventB.timestamp.to_i <=> eventA.timestamp.to_i }
    else 
      @collatingArray.sort! { |eventA, eventB| eventA.timestamp.to_i <=> eventB.timestamp.to_i }
    end
    @collatingDone = true
  end # def collate

  # Flush any pending messages.
  public
  def flush(options = {})
    events = []
    if (@collatingDone)
      @mutex.synchronize{
        while collatedEvent = @collatingArray.pop
          collatedEvent["tags"] = Array.new if collatedEvent["tags"].nil?
          collatedEvent["tags"] << "collated"
          events << collatedEvent
        end # while @collatingArray.pop
      }
      # reset collatingDone flag.
      @collatingDone = false
    end
    return events
  end # def flush
end #
