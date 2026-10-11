import Foundation
import Testing
@testable import SamsungTV4Mac

@Suite struct RangeTests {
    @Test func fullAndOpenRanges() {
        #expect(MediaServer.parseRange("bytes=0-", size: 100) == 0...99)
        #expect(MediaServer.parseRange("bytes=10-19", size: 100) == 10...19)
        #expect(MediaServer.parseRange("bytes=90-500", size: 100) == 90...99)
        #expect(MediaServer.parseRange("bytes=-10", size: 100) == 90...99)
    }

    @Test func invalidRanges() {
        #expect(MediaServer.parseRange("bytes=100-", size: 100) == nil)
        #expect(MediaServer.parseRange("bytes=20-10", size: 100) == nil)
        #expect(MediaServer.parseRange("items=0-1", size: 100) == nil)
        #expect(MediaServer.parseRange("bytes=0-", size: 0) == nil)
    }
}

@Suite struct TimeTests {
    @Test func parseAndFormat() {
        #expect(DLNAClient.parseTime("0:00:09.359") == 9.359)
        #expect(DLNAClient.parseTime("2:25:00") == 8700)
        #expect(DLNAClient.parseTime("NOT_IMPLEMENTED") == nil)
        #expect(DLNAClient.formatTime(8700.6) == "2:25:00")
        #expect(DLNAClient.formatTime(-5) == "0:00:00")
    }
}

@Suite struct PlanTests {
    private func media(format: String, video: String, tag: String = "", audio: [(String, Int)]) throws -> MediaInfo {
        var streams = [#"{"index":0,"codec_type":"video","codec_name":"\#(video)","codec_tag_string":"\#(tag)","width":720,"height":304,"avg_frame_rate":"24000/1001"}"#]
        for (i, a) in audio.enumerated() {
            streams.append(#"{"index":\#(i + 1),"codec_type":"audio","codec_name":"\#(a.0)","channels":\#(a.1)}"#)
        }
        let json = #"{"streams":[\#(streams.joined(separator: ","))],"format":{"format_name":"\#(format)","duration":"8700.58","size":"2348519424"}}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(MediaInfo.self, from: Data(json.utf8))
    }

    @Test func xvidAviNeedsVideoConversion() throws {
        let m = try media(format: "avi", video: "mpeg4", tag: "XVID", audio: [("ac3", 6)])
        let plan = PlaybackPlan(media: m, fileExtension: "avi")
        #expect(!plan.direct)
        #expect(plan.transcodeVideo)
        #expect(plan.transcodeAudio.isEmpty)
        #expect(plan.remux)
        #expect(m.video?.displayCodec == "MPEG4 (XVID)")

        let args = MediaTools.ffmpegArguments(input: URL(fileURLWithPath: "/in.avi"), output: URL(fileURLWithPath: "/out.mkv"), media: m, plan: plan)
        #expect(args.contains("h264_videotoolbox"))
        #expect(args.contains("-c:a:0") && args[args.firstIndex(of: "-c:a:0")! + 1] == "copy")
    }

    @Test func h264MkvPlaysDirectly() throws {
        let m = try media(format: "matroska,webm", video: "h264", audio: [("aac", 2), ("eac3", 6)])
        #expect(PlaybackPlan(media: m, fileExtension: "mkv").direct)
    }

    @Test func dtsIsReencodedVideoCopied() throws {
        let m = try media(format: "matroska,webm", video: "hevc", audio: [("dts", 8)])
        let plan = PlaybackPlan(media: m, fileExtension: "mkv")
        #expect(!plan.transcodeVideo)
        #expect(plan.transcodeAudio == [1])
        let args = MediaTools.ffmpegArguments(input: URL(fileURLWithPath: "/a.mkv"), output: URL(fileURLWithPath: "/b.mkv"), media: m, plan: plan)
        #expect(args.contains("-ac:a:0"))
        #expect(args[args.firstIndex(of: "-c:v")! + 1] == "copy")
    }
}

@Suite struct XMLTests {
    @Test func soapResponse() {
        let xml = #"<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><Track>1</Track><TrackDuration>2:25:00</TrackDuration><RelTime>0:00:09.359</RelTime></u:GetPositionInfoResponse></s:Body></s:Envelope>"#
        let v = XMLLeafParser.parse(Data(xml.utf8))
        #expect(v["TrackDuration"] == "2:25:00")
        #expect(v["RelTime"] == "0:00:09.359")
    }

    @Test func deviceDescription() {
        let xml = #"<root xmlns="urn:schemas-upnp-org:device-1-0"><device><friendlyName>[TV] Samsung 7 Series (55)</friendlyName><modelName>UE55RU7200UXRU</modelName><UDN>uuid:abc</UDN><serviceList><service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><controlURL>/upnp/control/RenderingControl1</controlURL></service><service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/upnp/control/AVTransport1</controlURL></service></serviceList></device></root>"#
        let p = DeviceDescriptionParser()
        #expect(p.parse(Data(xml.utf8)))
        #expect(p.friendlyName == "[TV] Samsung 7 Series (55)")
        #expect(p.udn == "uuid:abc")
        #expect(p.services.count == 2)
        #expect(p.services[1].controlURL == "/upnp/control/AVTransport1")
    }
}
