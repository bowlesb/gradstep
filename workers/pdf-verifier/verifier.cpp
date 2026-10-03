// Structural admission of original bytes, not PDF conformance or rendering.
// The external ABI is numeric. No document strings or diagnostics cross it.
#include <qpdf/QPDF.hh>
#include <qpdf/QPDFExc.hh>
#include <qpdf/QPDFLogger.hh>
#include <qpdf/QPDFPageDocumentHelper.hh>
#include <qpdf/QUtil.hh>
#include <qpdf/RandomDataProvider.hh>
#include <qpdf/qpdf-c.h>
#include <emscripten/stack.h>
#include <cstdint>
#include <cstring>
#include <new>
#include <stdexcept>
#include <unistd.h>

namespace {
constexpr uint32_t input_limit = 5 * 1024 * 1024;
constexpr size_t page_limit = 50;
constexpr size_t object_limit = 50000;
constexpr size_t stream_limit = 32 * 1024 * 1024;
constexpr size_t token_limit = 1000000;
enum Result : int {
    malformed = -1, encrypted = -2, unsupported = -3,
    resource_limit = -4, warnings = -5, internal_error = -6,
    input_limit_exceeded = -7, page_limit_exceeded = -8,
};
struct LimitExceeded {};

int limit_result(uint32_t before)
{
    uint32_t after = 0;
    if (qpdf_global_get_uint32(qpdf_p_limit_errors, &after) != qpdf_r_ok) return internal_error;
    return after == before ? 0 : resource_limit;
}

bool set_limit(qpdf_param_e parameter, uint32_t value)
{
    return qpdf_global_set_uint32(parameter, value) == qpdf_r_ok;
}

// qpdf sometimes needs random bytes while inspecting encryption dictionaries.
// Emscripten getentropy uses host Web Crypto, without a filesystem or network.
class HostEntropy final : public RandomDataProvider {
    void provideRandomData(unsigned char* data, size_t length) override
    {
        while (length) {
            const size_t count = length < 256 ? length : 256;
            if (getentropy(data, count)) throw std::runtime_error("host_entropy_unavailable");
            data += count;
            length -= count;
        }
    }
};

class BoundedDiscard final : public Pipeline {
    size_t remaining = stream_limit;
  public:
    BoundedDiscard() : Pipeline("bounded-discard", nullptr) {}
    void write(unsigned char const*, size_t length) override
    {
        if (length > remaining) throw LimitExceeded{};
        remaining -= length;
    }
    void finish() override {} // Never reset the per-document cumulative bound.
};

class BoundedContents final : public QPDFObjectHandle::ParserCallbacks {
    size_t remaining_bytes = stream_limit;
    size_t remaining_tokens = token_limit;
  public:
    void contentSize(size_t length) override
    {
        if (length > remaining_bytes) throw LimitExceeded{};
        remaining_bytes -= length;
    }
    void handleObject(QPDFObjectHandle) override
    {
        if (!remaining_tokens) throw LimitExceeded{};
        --remaining_tokens;
    }
    void handleEOF() override {}
};

bool pdf_whitespace(unsigned char byte)
{
    return byte == 0 || byte == 9 || byte == 10 || byte == 12 || byte == 13 || byte == 32;
}
} // namespace

extern "C" {
int pdfv_abi() { return 1; }
int pdfv_parser_version() { return 120402; }
int pdfv_stack_bytes() { return emscripten_stack_get_base() - emscripten_stack_get_end(); }

// Success is a positive resolved page count (1..50); every other code fails.
int pdfv_verify(const unsigned char* bytes, uint32_t length)
{
    if (!bytes || length < 8) return malformed;
    if (length > input_limit) return input_limit_exceeded;
    if (std::memcmp(bytes, "%PDF-", 5)) return malformed;
    uint32_t end = length;
    while (end && pdf_whitespace(bytes[end - 1])) --end;
    if (end < 5 || std::memcmp(bytes + end - 5, "%%EOF", 5)) return malformed;
    if (QPDF::QPDFVersion() != "12.4.2") return internal_error;

    uint32_t limits_before = 0;
    if (qpdf_global_get_uint32(qpdf_p_limit_errors, &limits_before) != qpdf_r_ok) return internal_error;
    try {
        static HostEntropy entropy;
        QUtil::setRandomDataProvider(&entropy);
        if (!set_limit(qpdf_p_parser_max_nesting, 64) ||
            !set_limit(qpdf_p_parser_max_errors, 1) ||
            !set_limit(qpdf_p_parser_max_container_size, 50000) ||
            !set_limit(qpdf_p_parser_max_container_size_damaged, 50000) ||
            !set_limit(qpdf_p_max_stream_filters, 8)) return internal_error;

        QPDF document;
        auto logger = QPDFLogger::create();
        logger->setInfo(logger->discard());
        logger->setWarn(logger->discard());
        logger->setError(logger->discard());
        document.setLogger(logger);
        document.setSuppressWarnings(true);
        document.setAttemptRecovery(false);
        document.processMemoryFile("candidate", reinterpret_cast<char const*>(bytes), length);
        if (auto result = limit_result(limits_before)) return result;
        if (document.isEncrypted()) return encrypted;
        if (document.anyWarnings()) return warnings;

        auto pages = QPDFPageDocumentHelper(document).getAllPages();
        if (auto result = limit_result(limits_before)) return result;
        if (document.anyWarnings()) return warnings;
        if (pages.empty()) return malformed;
        if (pages.size() > page_limit) return page_limit_exceeded;
        if (document.isLinearized() && !document.checkLinearization()) return warnings;

        if (document.getObjectCount() > object_limit) return resource_limit;
        auto objects = document.getAllObjects();
        if (objects.size() > object_limit) return resource_limit;
        BoundedDiscard discard;
        for (auto& object : objects) {
            if (object.isStream()) {
                auto filter = object.getDict().getKey("/Filter");
                const bool has_filter = !filter.isNull() && !(filter.isArray() && filter.getArrayNItems() == 0);
                bool attempted = false;
                // Unlike qpdf_check_pdf's writer, this path always requests
                // Flate decoding, checks the modern success flag and never
                // retries a failed decode as raw data.
                const bool okay = object.pipeStreamData(&discard, &attempted, 0, qpdf_dl_all, false, false);
                if (!okay) return malformed;
                if (has_filter && !attempted) return unsupported;
            }
            if (auto result = limit_result(limits_before)) return result;
            if (document.anyWarnings()) return warnings;
        }
        BoundedContents contents;
        for (auto& page : pages) {
            page.parseContents(&contents);
            if (auto result = limit_result(limits_before)) return result;
            if (document.anyWarnings()) return warnings;
        }
        return static_cast<int>(pages.size());
    } catch (LimitExceeded const&) {
        return resource_limit;
    } catch (QPDFExc const& error) {
        if (auto result = limit_result(limits_before)) return result;
        switch (error.getErrorCode()) {
        case qpdf_e_password: return encrypted;
        case qpdf_e_unsupported: return unsupported;
        case qpdf_e_internal:
        case qpdf_e_system: return internal_error;
        default: return malformed;
        }
    } catch (std::bad_alloc const&) {
        return resource_limit;
    } catch (...) {
        return internal_error;
    }
}
}
