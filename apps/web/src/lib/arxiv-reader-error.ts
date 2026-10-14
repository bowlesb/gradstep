const recovery = ' You can still download its PDF on this device.';
const messages: Record<string, string> = {
 'source-incomplete': 'arXiv’s HTML for this version contains a conversion error.',
 'source-unavailable': 'arXiv did not return readable HTML for this version.',
 limit: 'This paper exceeds the device reader’s preparation limits.',
 math: 'The HTML reader couldn’t preserve an equation in this paper.',
 figure: 'A figure in this paper couldn’t be prepared on this device.',
 reference: 'The HTML reader couldn’t resolve this paper’s internal references.',
 formatting: 'The HTML reader doesn’t yet support part of this paper’s formatting.',
 unknown: 'This version’s HTML could not be prepared completely.',
};

export function arxivPreparationMessage(reason: unknown): string {
 return (typeof reason === 'string' && Object.hasOwn(messages, reason) ? messages[reason] : messages.unknown) + recovery;
}
